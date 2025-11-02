const std = @import("std");
const clientError = @import("error.zig");
const Allocator = std.mem.Allocator;

const Method = enum {
    GET,
    // TODO: Here we can add other request methods
};

/// Parameters for the HTTP Request
/// All fields are optional
/// method defaults to GET
pub const HttpParams = struct {
    method: Method = Method.GET,
    body: ?[]const u8 = null,
    headers: ?std.StringHashMap([]const u8) = null,
};

/// Represents a parsed HTTP Response
/// Usually not constructed directly, but returned from HttpRequest.send()
pub const HttpResponse = struct {
    status_str: []const u8,
    status_code: u16,
    headers: std.StringHashMap([]const u8),
    body: []const u8,

    pub fn deinit(self: *HttpResponse) void {
        self.headers.deinit();
    }

    /// Simple helper to parse the body as JSON
    /// If you need more control over the parsing, use `std.json.parseFromSlice` directly
    pub fn json(self: HttpResponse, comptime T: type, allocator: Allocator) std.json.ParseError(std.json.Scanner)!std.json.Parsed(T) {
        return std.json.parseFromSlice(T, allocator, self.body, .{});
    }

    pub fn format(value: @This(), writer: anytype) !void {
        try writer.print("HttpResponse {{\n\tstatus_str: {s},\n\tstatus_code: {d},\n\theaders: {{\n", .{
            value.status_str,
            value.status_code,
        });

        var it = value.headers.iterator();
        while (it.next()) |entry| {
            try writer.print("\t\tHeader: {s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        try writer.print("\t}},\n\tbody: {s}\n}}", .{value.body});
    }
};

/// A simple HTTP client supporting GET requests
/// It supports adding headers
/// Example Usage:
///     General Request with host and path:
///     ```
///         const allocator = std.testing.allocator;
///         var httpRequest = try HttpRequest.init(allocator, "httpbin.io", "/get", HttpParams{});
///         defer httpRequest.deinit();
///         const response = try httpRequest.send();
///         defer response.deinit();
///     ```
///
/// General Request with complete URL:
///     ```
///         const allocator = std.testing.allocator;
///         var httpRequest = try HttpRequest.request(allocator, "http://httpbin.io/get", HttpParams{});
///         defer httpRequest.deinit();
///         const response = try httpRequest.send();
///         defer response.deinit();
///     ```
///
/// Simple Get Request
///     ```
///         const allocator = std.testing.allocator;
///         var httpRequest = try HttpRequest.get(allocator, "http://httpbin.io/get");
///         defer httpRequest.deinit();
///         const response = try httpRequest.send();
///         defer response.deinit();
///     ```
///
/// TODO : Add HTTPs support
pub const HttpRequest = struct {
    allocator: Allocator,
    connection: std.net.Stream,
    host_name: []const u8,
    uri: std.Uri,
    params: HttpParams,
    requestString: ?[]const u8 = undefined,
    responseString: ?[]const u8 = undefined,

    /// Creates a HttpRequest for a given server address and path
    /// Refer to the `HttpRequest` documentation for example usage
    /// The path argument needs to be percent-encoded
    /// Example Usage
    /// ```
    ///  const allocator = std.testing.allocator;
    ///  var httpRequest = try HttpRequest.init(allocator, "httpbin.io", "/get?params=1&test=%2Fnicoco", HttpParams{});
    ///  defer httpRequest.deinit();
    /// ```
    /// Note that params.headers' ownership is transferred to the HttpRequest.
    /// The struct is responsible for freeing the memory
    /// Dev: This was added to fit the API requirements from the task.
    /// Dev: Though the `get` API is preferable since it simplifies the usage.
    pub fn init(allocator: Allocator, address: []const u8, path: []const u8, params: ?HttpParams) clientError.HttpClientInitError!HttpRequest {
        const uri = std.Uri{
            .scheme = "http",
            .host = std.Uri.Component{ .raw = address },
            .path = std.Uri.Component{ .percent_encoded = path },
        };
        return HttpRequest.initWithUri(allocator, uri, params);
    }

    /// Creates a HttpRequest for a given address
    /// This is the general and preferred entry point for creating HTTP requests
    /// Refer to the `HttpRequest` documentation for example usage
    pub fn request(allocator: Allocator, address: []const u8, params: ?HttpParams) clientError.HttpClientInitError!HttpRequest {
        const uri = try std.Uri.parse(address);
        return HttpRequest.initWithUri(allocator, uri, params);
    }

    /// Simplified API to send a simple GET request to a given address
    pub fn get(allocator: Allocator, address: []const u8) clientError.HttpClientInitError!HttpRequest {
        return HttpRequest.request(allocator, address, HttpParams{ .method = Method.GET });
    }

    /// General Request Creation API for users that need more control
    pub fn initWithUri(allocator: Allocator, uri: std.Uri, params: ?HttpParams) clientError.HttpClientInitError!HttpRequest {
        var host_name_buffer: [std.Uri.host_name_max]u8 = undefined;
        const host_name = try uri.getHost(&host_name_buffer);

        // Default port when it's not specified
        // TODO : Change when implementing HTTPS
        const uriPort = uri.port orelse 80;

        const connection = try std.net.tcpConnectToHost(allocator, host_name, uriPort);

        return HttpRequest{
            .allocator = allocator,
            .connection = connection,
            .host_name = host_name,
            .uri = uri,
            .params = params orelse HttpParams{},
            .requestString = null,
            .responseString = null,
        };
    }

    /// Release the resources held by the HttpRequest
    /// I.E. free the allocated request and response strings
    /// Also frees the response object if it was created
    pub fn deinit(self: *HttpRequest) void {
        if (self.requestString != null) {
            self.allocator.free(self.requestString.?);
        }
        if (self.responseString != null) {
            self.allocator.free(self.responseString.?);
        }
        self.connection.close();
        if (self.params.headers != null) {
            self.params.headers.?.deinit();
        }
    }

    /// Sends the Http Request
    /// Returns a HttpResponse struct containing the parsed response data
    /// HttpResponse is allocated on the head, the caller is responsible for freeing the corresponding memory
    pub fn send(self: *HttpRequest) clientError.HttpClientSendError!HttpResponse {
        // Creating the request string
        self.requestString = try self.createHttpRequestString();

        // Sending the bytes
        var writer = self.connection.writer(&.{});
        try writer.interface.writeAll(self.requestString.?);

        // Reading the response. Saving that in case the user wants to use it
        const responseString = try self.readResponse();
        self.responseString = responseString;

        // Parsing the HTTP Response
        const response = try self.parseResponse();
        return response;
    }

    /// Internals: Create the HTTP Request String from the given parameters
    /// Creates a HTTP/1.0 request string
    fn createHttpRequestString(self: *HttpRequest) clientError.HttpClientCreateRequestError![]const u8 {
        var requestWriter = try std.io.Writer.Allocating.initCapacity(self.allocator, 1024);
        defer requestWriter.deinit();
        var w = &requestWriter.writer;

        try w.print("{s} ", .{@tagName(self.params.method)});
        if (self.uri.path.isEmpty()) {
            try w.writeAll("/");
        } else {
            try self.uri.path.formatPath(w);
        }
        if (self.uri.query != null) {
            try w.writeAll("?");
            try self.uri.query.?.formatQuery(w);
        }
        // TODO : change when integrating HTTP/2
        try w.writeAll(" HTTP/1.0\r\n");

        // First line is done, now to the headers
        try w.print("Host: {s}\r\n", .{self.host_name});

        // We add the passed headers
        if (self.params.headers != null) {
            var it = self.params.headers.?.iterator();
            while (it.next()) |req| {
                try w.print("{s}: {s}\r\n", .{ req.key_ptr.*, req.value_ptr.* });
            }
        }
        try w.writeAll("\r\n");

        // TODO : Here we can add the request body if any
        const requestString = try requestWriter.toOwnedSlice();

        return requestString;
    }

    /// Internals: Reads the response from the HTTP Request into a struct owned string
    /// Dev: No parsing is done in this function
    fn readResponse(self: *HttpRequest) clientError.HttpClientReadResponseError![]const u8 {

        // Didn't find an alternative to reading the stream 1kb at a time
        var responseWriter = try std.io.Writer.Allocating.initCapacity(self.allocator, 1024);
        defer responseWriter.deinit();
        var w = &responseWriter.writer;
        var reader = self.connection.reader(&.{});

        while (true) {
            const dest = try self.allocator.alloc(u8, 1024);
            defer self.allocator.free(dest);
            const len = try reader.interface().readSliceShort(dest);
            if (len == 0) break;
            try w.writeAll(dest[0..len]);
        }
        return try responseWriter.toOwnedSlice();
    }

    /// Internals: Parses the HTTP response.
    /// TODO : Only support HTTP/1.0 for now.
    fn parseResponse(self: *HttpRequest) clientError.HttpClientParseResponseError!HttpResponse {
        const response = self.responseString.?;

        // First parse the headers
        const headerEnd = try findDoubleCRLF(response);
        const headString = response[0 .. headerEnd - 4];

        var it = std.mem.splitSequence(u8, headString, "\r\n");
        // First the status line
        const statusLine = it.next() orelse return error.InvalidHttpResponse;
        var statusLineIt = std.mem.splitScalar(u8, statusLine, ' ');
        const httpVersion = statusLineIt.next() orelse return error.InvalidHttpResponse;
        const statusCode = statusLineIt.next() orelse return error.InvalidHttpResponse;
        const statusCodeStr = statusLineIt.rest();

        // We only handle HTTP/1.0 for now
        if (!std.mem.eql(u8, httpVersion, "HTTP/1.0")) return error.UnsupportedHttpVersion;

        // Then all the headers
        var headers = std.StringHashMap([]const u8).init(self.allocator);
        while (it.next()) |x| {
            var headerIt = std.mem.splitSequence(u8, x, ": ");
            const key = headerIt.next() orelse return error.InvalidHeaderPair;
            const value = headerIt.next() orelse return error.InvalidHeaderPair;
            try headers.put(key, value);
        }

        // Parsing the body
        // For now, we don't consider the Chuncked Transfer Encoding, so we can just return the whole body bytes
        const body = response[headerEnd..];

        // Then parse the rest of the response
        return HttpResponse{ .status_code = try std.fmt.parseInt(u16, statusCode, 10), .status_str = statusCodeStr, .headers = headers, .body = body };
    }
};

/// Returns the location of the first occurrence of "\r\n\r\n" in the buffer
fn findDoubleCRLF(buffer: []const u8) error{DoubleCRLFNotFound}!usize {
    for (buffer[0 .. buffer.len - 3], 0..) |_, i| {
        if (buffer[i] == '\r' and buffer[i + 1] == '\n' and buffer[i + 2] == '\r' and buffer[i + 3] == '\n') {
            return i + 4; // position just after the header
        }
    }
    return error.DoubleCRLFNotFound;
}

// *** Unit Tests *** //

test "http request format with headers" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("User-Agent", "ZigTestClient");
    try headers.put("Accept", "*/*");

    var httpRequest = try HttpRequest.init(allocator, "example.com", "/test", HttpParams{ .method = Method.GET, .headers = headers });
    defer httpRequest.deinit();

    const requestString = try httpRequest.createHttpRequestString();
    defer allocator.free(requestString);

    const expectedRequest = "GET /test HTTP/1.0\r\nHost: example.com\r\nUser-Agent: ZigTestClient\r\nAccept: */*\r\n\r\n";
    try std.testing.expectEqualStrings(requestString, expectedRequest);
}

test "http response parsing" {
    const allocator = std.testing.allocator;

    const headers = std.StringHashMap([]const u8).init(allocator);

    var httpRequest = try HttpRequest.init(allocator, "example.com", "/test", HttpParams{ .method = Method.GET, .headers = headers });
    defer httpRequest.deinit();

    const responseString = try allocator.dupe(u8, "HTTP/1.0 200 OK\r\nUser-Agent-Return: ZigTestClient\r\nAccept-Return: */*\r\n\r\nHello, World!");
    httpRequest.responseString = responseString;
    var response = try httpRequest.parseResponse();
    defer response.deinit();
    try std.testing.expectEqual(response.status_code, 200);
    try std.testing.expectEqualStrings(response.status_str, "OK");
    try std.testing.expectEqualStrings(response.headers.get("User-Agent-Return").?, "ZigTestClient");
    try std.testing.expectEqualStrings(response.headers.get("Accept-Return").?, "*/*");
    try std.testing.expectEqualStrings(response.body, "Hello, World!");
}

test "http request percent encoding" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("User-Agent", "ZigTestClient");
    try headers.put("Accept", "*/*");

    var httpRequest = try HttpRequest.init(allocator, "example.com", "/test?param=%2Fnicoco", HttpParams{ .method = Method.GET, .headers = headers });
    defer httpRequest.deinit();

    const requestString = try httpRequest.createHttpRequestString();
    defer allocator.free(requestString);

    const expectedRequest = "GET /test?param=%2Fnicoco HTTP/1.0\r\nHost: example.com\r\nUser-Agent: ZigTestClient\r\nAccept: */*\r\n\r\n";
    try std.testing.expectEqualStrings(requestString, expectedRequest);
}
