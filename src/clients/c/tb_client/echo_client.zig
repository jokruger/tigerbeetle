const std = @import("std");
const stdx = @import("../../../stdx.zig");
const assert = std.debug.assert;
const mem = std.mem;

const constants = @import("../../../constants.zig");
const vsr = @import("../../../vsr.zig");
const Header = vsr.Header;

const IOPS = @import("../../../iops.zig").IOPS;
const RingBuffer = @import("../../../ring_buffer.zig").RingBuffer;
const MessagePool = @import("../../../message_pool.zig").MessagePool;
const Message = @import("../../../message_pool.zig").MessagePool.Message;

pub fn EchoClient(comptime StateMachine_: type, comptime MessageBus: type) type {
    return struct {
        const Self = @This();

        // Exposing the same types the real client does:
        const VSRClient = @import("../../../vsr/client.zig").Client(StateMachine_, MessageBus);
        pub const StateMachine = VSRClient.StateMachine;
        pub const Request = VSRClient.Request;

        id: u128,
        cluster: u128,
        request_number: u32 = 1,
        messages_available: u32 = constants.client_request_queue_max,
        request_inflight: ?Request = null,
        message_pool: *MessagePool,

        pub fn init(
            allocator: mem.Allocator,
            id: u128,
            cluster: u128,
            replica_count: u8,
            message_pool: *MessagePool,
            message_bus_options: MessageBus.Options,
        ) !Self {
            _ = allocator;
            _ = replica_count;
            _ = message_bus_options;

            return Self{
                .id = id,
                .cluster = cluster,
                .message_pool = message_pool,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            _ = allocator;
            if (self.request_inflight) |inflight| self.release_message(inflight.message.base());
        }

        pub fn tick(self: *Self) void {
            const inflight = self.request_inflight orelse return;
            self.request_inflight = null;

            // Allocate a reply message.
            const reply = self.get_message().build(.request);
            defer self.release_message(reply.base());

            // Copy the request message's entire content including header into the reply.
            const operation = inflight.message.header.operation.cast(Self.StateMachine);
            stdx.copy_disjoint(
                .exact,
                u8,
                reply.buffer,
                inflight.message.buffer,
            );

            // Similarly to the real client, release the request message before invoking the
            // callback. This necessitates a `copy_disjoint` above.
            self.release_message(inflight.message.base());
            inflight.callback(
                inflight.user_data,
                operation,
                reply.body(),
            );
        }

        pub fn request(
            self: *Self,
            callback: Request.Callback,
            user_data: u128,
            operation: StateMachine.Operation,
            events: []const u8,
        ) void {
            const event_size: usize = switch (operation) {
                inline else => |operation_comptime| @sizeOf(StateMachine.Event(operation_comptime)),
            };
            assert(events.len <= constants.message_body_size_max);
            assert(events.len % event_size == 0);

            const message = self.get_message().build(.request);
            errdefer self.release_message(message.base());

            message.header.* = .{
                .client = self.id,
                .request = undefined, // Set by raw_request() below.
                .cluster = self.cluster,
                .command = .request,
                .release = vsr.Release.minimum,
                .operation = vsr.Operation.from(StateMachine, operation),
                .size = @intCast(@sizeOf(Header) + events.len),
            };

            stdx.copy_disjoint(.exact, u8, message.body(), events);
            self.raw_request(callback, user_data, message);
        }

        pub fn raw_request(
            self: *Self,
            callback: Request.Callback,
            user_data: u128,
            message: *Message.Request,
        ) void {
            assert(message.header.client == self.id);
            assert(message.header.cluster == self.cluster);
            assert(!message.header.operation.vsr_reserved());
            assert(message.header.size >= @sizeOf(Header));
            assert(message.header.size <= constants.message_size_max);

            message.header.request = self.request_number;
            self.request_number += 1;

            assert(self.request_inflight == null);
            self.request_inflight = .{
                .message = message,
                .user_data = user_data,
                .callback = callback,
            };
        }

        pub fn get_message(self: *Self) *Message {
            assert(self.messages_available > 0);
            self.messages_available -= 1;
            return self.message_pool.get_message(null);
        }

        pub fn release_message(self: *Self, message: *Message) void {
            assert(self.messages_available < constants.client_request_queue_max);
            self.messages_available += 1;
            self.message_pool.unref(message);
        }
    };
}
