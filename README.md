# Http Client

This library is an HTTP Client used that can

## Features

- HTTP 1.0 requests ✅
  - Plain GET Request ✅
  - Headers ✅
- Complete Address parsing ✅

## Get Started

To use that library in your project, run the following commands:

```bash
zig fetch --save git+https://github.com/Kayanski/lightpanda-technical-assignment/#HEAD
```

Then don't forget to amend your `build.zig.zon` file with the following lines. This will allow you to import the `http_client` module into your project.

```zig
const http_client = b.dependency("http_client", .{});
exe.root_module.addImport("http_client", http_client.module("http_client"));
```

## Usage

Here are some example usage snippets

```zig
const std = @import("std");
const http_client = @import("http_client");

// Create a simple request, send it and analyze the response
const allocator = std.heap.page_allocator;
// For simpler syntax, one can also use 
// var httpRequest = try http_client.HttpRequest.get(allocator, "http://httpbin.io/get?test_param=1&another_param=%2Fnicoco");
var httpRequest = try http_client.HttpRequest.init(allocator, "httpbin.io", "/get?test_param=1&another_param=%2Fnicoco", http_client.HttpParams{});
defer httpRequest.deinit();
var response = try httpRequest.send();
defer response.deinit();

try std.testing.expectEqual(200, response.status_code);
try std.testing.expectEqualStrings("OK", response.status_str);

// Parsing the response body to JSON and matching the results
const HttpBinGetResponseBody = struct { args: std.json.Value, headers: std.json.Value, method: []const u8, origin: []const u8, url: []const u8 };
const parsedBody = try response.json(HttpBinGetResponseBody, allocator);
switch (parsedBody.value.args) {
    .object => {
        const testParamValue = parsedBody.value.args.object.get("test_param").?.array.items[0].string;
        try std.testing.expectEqualStrings("1", testParamValue);
        const anotherParamValue = parsedBody.value.args.object.get("another_param").?.array.items[0].string;
        try std.testing.expectEqualStrings("/nicoco", anotherParamValue);
    },
    else => return error.ArgsIsNotAnObject,
}
```

## Upcoming Features

- TLS Support ❌
- Supports additional request types (POST, PATCH) ❌
