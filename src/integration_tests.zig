const std = @import("std");
const http_client = @import("root.zig");

const HttpRequest = http_client.HttpRequest;
const HttpParams = http_client.HttpParams;

const HttpBinGetResponseBody = struct { args: std.json.Value, headers: std.json.Value, method: []const u8, origin: []const u8, url: []const u8 };

test "http get request with headers" {
    const allocator = std.testing.allocator;

    var headers = std.StringHashMap([]const u8).init(allocator);
    try headers.put("x-test-header", "test-value");

    const url = "http://httpbin.io/get?test_param=1";
    var httpRequest = try HttpRequest.request(allocator, url, HttpParams{
        .headers = headers,
    });
    defer httpRequest.deinit();
    var response = try httpRequest.send();
    defer response.deinit();

    try std.testing.expectEqual(200, response.status_code);
    try std.testing.expectEqualStrings("OK", response.status_str);

    const parsedBody = try response.json(HttpBinGetResponseBody, allocator);
    defer parsedBody.deinit();

    try std.testing.expectEqualStrings("GET", parsedBody.value.method);
    try std.testing.expectEqualStrings(url, parsedBody.value.url);

    switch (parsedBody.value.args) {
        .object => {
            const testParamValue = parsedBody.value.args.object.get("test_param").?.array.items[0].string;
            try std.testing.expectEqualStrings("1", testParamValue);
        },
        else => return error.ArgsIsNotAnObject,
    }

    switch (parsedBody.value.headers) {
        .object => {
            const hostValue = parsedBody.value.headers.object.get("Host").?.array.items[0].string;
            try std.testing.expectEqualStrings("httpbin.io", hostValue);

            const testHeaderValue = parsedBody.value.headers.object.get("X-Test-Header").?.array.items[0].string;
            try std.testing.expectEqualStrings("test-value", testHeaderValue);
        },
        else => return error.ArgsIsNotAnObject,
    }
}

test "basic http get request" {
    const allocator = std.testing.allocator;

    const url = "http://httpbin.io/get?test_param=1";

    var httpRequest = try HttpRequest.get(allocator, url);
    defer httpRequest.deinit();
    var response = try httpRequest.send();
    defer response.deinit();

    try std.testing.expectEqual(200, response.status_code);
    try std.testing.expectEqualStrings("OK", response.status_str);

    const parsedBody = try response.json(HttpBinGetResponseBody, allocator);
    defer parsedBody.deinit();

    try std.testing.expectEqualStrings("GET", parsedBody.value.method);
    try std.testing.expectEqualStrings(url, parsedBody.value.url);

    switch (parsedBody.value.args) {
        .object => {
            const testParamValue = parsedBody.value.args.object.get("test_param").?.array.items[0].string;
            try std.testing.expectEqualStrings("1", testParamValue);
        },
        else => return error.ArgsIsNotAnObject,
    }
}

test "basic http get request using init" {
    const allocator = std.testing.allocator;

    var httpRequest = try HttpRequest.init(allocator, "httpbin.io", "/get?test_param=1&another_param=%2Fnicoco", HttpParams{});
    defer httpRequest.deinit();
    var response = try httpRequest.send();
    defer response.deinit();

    try std.testing.expectEqual(200, response.status_code);
    try std.testing.expectEqualStrings("OK", response.status_str);

    const parsedBody = try response.json(HttpBinGetResponseBody, allocator);
    defer parsedBody.deinit();

    try std.testing.expectEqualStrings("GET", parsedBody.value.method);
    try std.testing.expectEqualStrings("http://httpbin.io/get?test_param=1&another_param=%2Fnicoco", parsedBody.value.url);

    switch (parsedBody.value.args) {
        .object => {
            const testParamValue = parsedBody.value.args.object.get("test_param").?.array.items[0].string;
            try std.testing.expectEqualStrings("1", testParamValue);
            const anotherParamValue = parsedBody.value.args.object.get("another_param").?.array.items[0].string;
            try std.testing.expectEqualStrings("/nicoco", anotherParamValue);
        },
        else => return error.ArgsIsNotAnObject,
    }
}
