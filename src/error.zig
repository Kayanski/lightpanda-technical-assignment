const std = @import("std");

pub const HttpClientInitError = error{ UriMissingHost, UriHostTooLong } || std.net.TcpConnectToHostError || std.Uri.ParseError;

pub const HttpClientCreateRequestError = error{ OutOfMemory, WriteFailed };
pub const HttpClientReadResponseError = error{OutOfMemory} || std.Io.Reader.Error || std.Io.Writer.Error;
pub const HttpClientParseResponseError = error{ InvalidHttpResponse, InvalidHeaderPair, UnsupportedHttpVersion, DoubleCRLFNotFound } || std.mem.Allocator.Error || std.fmt.ParseIntError;
pub const HttpClientSendError = HttpClientCreateRequestError || HttpClientReadResponseError || HttpClientParseResponseError || std.Io.Writer.Error;
