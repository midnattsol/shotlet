//! Native DBus client: speaks the wire protocol directly over the session bus
//! unix socket. No libdbus. Little-endian only (x86_64/aarch64 linux).
//!
//! Facade over dbus/: address (bus address lists), marshal (body builder),
//! reader (unmarshalling), message (model and headers), auth (SASL),
//! transport (framing and fd passing), connection (calls, waits and the
//! org.freedesktop.DBus helpers), errors (error-reply classification)
//! and properties (answering Properties calls on our own objects).

const address = @import("dbus/address.zig");
const marshal = @import("dbus/marshal.zig");
const reader = @import("dbus/reader.zig");
const message = @import("dbus/message.zig");
const transport = @import("dbus/transport.zig");
const connection = @import("dbus/connection.zig");
const errors = @import("dbus/errors.zig");

pub const MessageType = message.MessageType;
pub const Message = message.Message;
pub const Marshal = marshal.Marshal;
pub const Value = reader.Value;
pub const Reader = reader.Reader;
pub const Address = address.Address;
pub const parseAddresses = address.parseAddresses;
pub const isFatal = transport.isFatal;
pub const default_reply_timeout_ms = transport.default_reply_timeout_ms;
pub const Connection = connection.Connection;
pub const Property = connection.Property;
pub const properties_iface = connection.properties_iface;
pub const NameOwnerChange = connection.NameOwnerChange;
pub const nameOwnerChange = connection.nameOwnerChange;
pub const ErrorKind = errors.ErrorKind;
pub const CallError = errors.CallError;
pub const classify = errors.classify;
pub const makeToken = marshal.makeToken;
/// Answering Properties Get/GetAll on our own objects: Properties.reply.
pub const Properties = @import("dbus/properties.zig");

comptime {
    _ = address;
    _ = marshal;
    _ = reader;
    _ = message;
    _ = @import("dbus/auth.zig");
    _ = transport;
    _ = connection;
    _ = errors;
    _ = Properties;
}
