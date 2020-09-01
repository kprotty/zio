// Copyright (c) 2020 kprotty
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// 	http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const zap = @import("../../zap.zig");

pub fn Channel(comptime T: type) type {
    return struct {
        const Self = @This();

        const Waiter = struct {
            next: ?*Waiter,
            last: *Waiter,
            task: zap.Task,
            item: Item,

            const Item = union(enum) {
                some: T,
                none: void,
                closed: void,
            };

            const Queue = struct {
                head: ?*Waiter = null,

                fn push(self: *Queue, waiter: *Waiter) void {
                    waiter.next = null;
                    waiter.last = waiter;
                    if (self.head) |head| {
                        head.last.next = waiter;
                        head.last = waiter;
                    } else {
                        self.head = waiter;
                    }
                }

                fn pop(self: *Queue) ?*Waiter {
                    const waiter = self.head orelse return null;
                    self.head = waiter.next;
                    return waiter;
                }

                fn consume(self: *Queue, other: *Queue) void {
                    const other_head = other.head orelse return;
                    other.head = null;
                    if (self.head) |head| {
                        head.last.next = other_head;
                        head.last = other_head.last;
                    } else {
                        self.head = other_head;
                    }
                }
            };
        };

        lock: zap.sync.os.Lock = zap.sync.os.Lock{},
        putters: Waiter.Queue = Waiter.Queue{},
        getters: Waiter.Queue = Waiter.Queue{},
        head: usize = 0,
        tail: usize = 0,
        buffer_ptr: [*]T,
        buffer_len: usize,

        const CLOSED = @intToPtr([*]T, std.mem.alignBackward(std.math.maxInt(usize), @alignOf(T)));

        pub fn from(buffer: []T) Self {
            if (buffer.ptr == CLOSED)
                std.debug.panic("invalid buffer ptr", .{});
            return Self{
                .buffer_ptr = buffer.ptr,
                .buffer_len = buffer.len,
            };
        }

        pub fn close(self: *Self) void {
            if (@atomicLoad([*]T, &self.buffer_ptr, .Unordered) == CLOSED) {
                return;
            } else {
                @atomicStore([*]T, &self.buffer_ptr, CLOSED, .Unordered);
            }

            var waiters = Waiter.Queue{};
            {
                self.lock.acquire();
                defer self.lock.release();

                waiters.consume(&self.putters);
                waiters.consume(&self.getters);
            }

            var batch = zap.Task.Batch{};
            while (waiters.pop()) |waiter| {
                batch.push(&waiter.task);
                waiter.item = Waiter.Item{ .closed = {} };
            }
            batch.schedule();
        }

        pub fn put(self: *Self, item: T) error{Closed}!void {
            if (@atomicLoad([*]T, &self.buffer_ptr, .Unordered) == CLOSED)
                return error.Closed;

            self.lock.acquire();

            const buffer_ptr = @atomicLoad([*]T, &self.buffer_ptr, .Unordered);
            if (buffer_ptr == CLOSED) {
                self.lock.release();
                return error.Closed;
            }

            if (self.getters.pop()) |waiter| {
                self.lock.release();

                waiter.item = Waiter.Item{ .some = item };
                waiter.task.schedule();
                return;
            }

            if (self.tail -% self.head < self.buffer_len) {
                buffer_ptr[self.tail % self.buffer_len] = item;
                self.tail +%= 1;
                self.lock.release();
                return;
            }

            var waiter: Waiter = undefined;
            waiter.task = zap.Task.from(@frame());
            waiter.item = Waiter.Item{ .some = item };
            self.putters.push(&waiter);

            suspend {
                self.lock.release();
            }

            return switch (waiter.item) {
                .some => unreachable,
                .none => {},
                .closed => error.Closed,
            };
        }

        pub fn get(self: *Self) error{Closed}!T {
            if (@atomicLoad([*]T, &self.buffer_ptr, .Unordered) == CLOSED)
                return error.Closed;

            self.lock.acquire();
            
            const buffer_ptr = @atomicLoad([*]T, &self.buffer_ptr, .Unordered);
            if (buffer_ptr == CLOSED) {
                self.lock.release();
                return error.Closed;
            }

            if (self.putters.pop()) |waiter| {
                self.lock.release();
                
                const item = waiter.item.some;
                waiter.item = Waiter.Item{ .none = {} };
                waiter.task.schedule();
                
                return item;
            }

            if (self.tail != self.head) {
                const item = buffer_ptr[self.head % self.buffer_len];
                self.head +%= 1;
                self.lock.release();
                return item;
            }

            var waiter: Waiter = undefined;
            waiter.task = zap.Task.from(@frame());
            waiter.item = Waiter.Item{ .none = {} };
            self.getters.push(&waiter);

            suspend {
                self.lock.release();
            }

            return switch (waiter.item) {
                .some => |item| item,
                .none => unreachable,
                .closed => error.Closed,
            };
        }
    };
}