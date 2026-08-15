const std = @import("std");
const r4os = @import("r4os");
const r4img = @import("r4img");

const response_capacity: usize = 256 * 1024;
const tls_workspace_capacity: usize = r4os.app_web.tls_workspace_bytes;
const tls_scratch_capacity: usize = r4os.app_web.tls_scratch_bytes;
const tls_envelope_header_len: usize = 12;
const tls_client_secret_len: usize = 32;
const tls_client_random_len: usize = 32;
const tls_client_state_header_len: usize = 4 + 8 + 2 + tls_client_secret_len + tls_client_random_len + 4;
const tls_stream_state_len: usize = 140;
const tls_client_ready_header_len: usize = 4 + tls_stream_state_len + 4;
const default_url = "https://www.google.com/";
const default_consent_url = "https://www.google.com/search?q=R4OS";
const default_page_url = "https://marginalia-search.com/search?query=R4OS";
const consent_switch = "/CONSENT";
const warmup_switch = "/WARM";
const page_switch = "/PAGE";
const image_switch = "/IMAGE";
const form_target_capacity: usize = r4os.web_navigation.url_capacity + 1;
const form_body_capacity: usize = 8 * 1024;
// The live acceptance follows the productive browser policy so a finite
// challenge proven offline can also finish in the guest. Progress remains
// observable without invoking the host callback for every VM instruction.
const script_step_budget: usize = 16 * 1024 * 1024;
const script_stop_check_interval: usize = 64;
const max_script_navigations: usize = 2;

const Buffers = struct {
    raw: [response_capacity]u8,
    body: [response_capacity]u8,
    scratch: [tls_scratch_capacity]u8,
};

const BrowserProbe = struct {
    document: r4os.html.Document,
    stylesheet: r4os.css.Stylesheet,
    interaction: r4os.web_forms.Interaction,
    layout: r4os.web_layout.Layout,

    fn load(self: *BrowserProbe, source: []const u8, content_type: []const u8) !void {
        self.document = .{};
        self.stylesheet = .{};
        self.interaction = .{};
        self.layout = .{};
        _ = try self.document.parse(source, .{ .content_type = content_type, .require_html_mime = true });
        try self.stylesheet.appendDocumentStyles(&self.document);
        try self.interaction.rebuild(&self.document);
        _ = try self.layout.reflow(&self.document, &self.stylesheet, .{ .width = 940, .height = 480 });
    }

    fn firstVisibleSubmit(self: *const BrowserProbe) ?u16 {
        var control_index: usize = 0;
        while (control_index < self.interaction.control_count) : (control_index += 1) {
            const control = self.interaction.controls[control_index];
            if (control.kind != .submit or !self.nodeVisible(control.node)) continue;
            return control.node;
        }
        return null;
    }

    fn nodeVisible(self: *const BrowserProbe, node: u16) bool {
        var index: usize = 0;
        while (index < self.layout.op_count) : (index += 1) {
            const op = self.layout.ops[index];
            if (op.kind != .text or self.layout.text(op).len == 0) continue;
            var current = op.node;
            while (current != r4os.html.none and current < self.document.node_count) {
                if (current == node) return true;
                current = self.document.nodes[current].parent;
            }
        }
        return false;
    }

    fn visibleLinkCount(self: *const BrowserProbe) usize {
        var count: usize = 0;
        var index: usize = 0;
        while (index < self.document.node_count) : (index += 1) {
            const node: u16 = @intCast(index);
            if (self.document.nodes[node].kind != .element or !std.ascii.eqlIgnoreCase(self.document.nodeName(node), "a")) continue;
            const href = self.document.attribute(node, "href") orelse continue;
            if (href.len == 0 or !self.nodeVisible(node)) continue;
            count += 1;
        }
        return count;
    }

    fn visibleHeadingLinkCount(self: *const BrowserProbe) usize {
        var count: usize = 0;
        var index: usize = 0;
        while (index < self.document.node_count) : (index += 1) {
            const node: u16 = @intCast(index);
            if (self.document.nodes[node].kind != .element or !std.ascii.eqlIgnoreCase(self.document.nodeName(node), "a")) continue;
            const href = self.document.attribute(node, "href") orelse continue;
            if (href.len == 0 or !self.nodeVisible(node) or (!self.hasHeadingDescendant(node) and !self.hasHeadingAncestor(node))) continue;
            count += 1;
        }
        return count;
    }

    fn visibleHeadingCount(self: *const BrowserProbe) usize {
        var count: usize = 0;
        var index: usize = 0;
        while (index < self.document.node_count) : (index += 1) {
            const node: u16 = @intCast(index);
            if (self.document.nodes[node].kind != .element or !isHeading(self.document.nodeName(node)) or !self.nodeVisible(node)) continue;
            count += 1;
        }
        return count;
    }

    fn visibleElementCount(self: *const BrowserProbe, element_name: []const u8) usize {
        var count: usize = 0;
        var index: usize = 0;
        while (index < self.document.node_count) : (index += 1) {
            const node: u16 = @intCast(index);
            if (self.document.nodes[node].kind != .element or !std.ascii.eqlIgnoreCase(self.document.nodeName(node), element_name) or !self.nodeVisible(node)) continue;
            count += 1;
        }
        return count;
    }

    fn visibleTextStats(self: *const BrowserProbe) struct { ops: usize, bytes: usize } {
        var ops: usize = 0;
        var bytes: usize = 0;
        var index: usize = 0;
        while (index < self.layout.op_count) : (index += 1) {
            const op = self.layout.ops[index];
            if (op.kind != .text) continue;
            const value = self.layout.text(op);
            if (value.len == 0) continue;
            ops += 1;
            bytes += value.len;
        }
        return .{ .ops = ops, .bytes = bytes };
    }

    fn hasHeadingDescendant(self: *const BrowserProbe, ancestor: u16) bool {
        var index: usize = 0;
        while (index < self.document.node_count) : (index += 1) {
            const candidate: u16 = @intCast(index);
            if (self.document.nodes[candidate].kind != .element or !isHeading(self.document.nodeName(candidate))) continue;
            var current = self.document.nodes[candidate].parent;
            while (current != r4os.html.none and current < self.document.node_count) {
                if (current == ancestor) return true;
                current = self.document.nodes[current].parent;
            }
        }
        return false;
    }

    fn hasHeadingAncestor(self: *const BrowserProbe, node_input: u16) bool {
        var node = self.document.nodes[node_input].parent;
        var visited: usize = 0;
        while (node != r4os.html.none and node < self.document.node_count and visited < r4os.html.max_depth) : (visited += 1) {
            if (self.document.nodes[node].kind == .element and isHeading(self.document.nodeName(node))) return true;
            node = self.document.nodes[node].parent;
        }
        return false;
    }
};

const CookieContext = struct {
    storage: *r4os.web_security.BrowserStorage,
};

const RuntimeAllocatorContext = struct {
    allocator: std.mem.Allocator,
};

const ScriptTraceContext = struct {
    sys: r4os.r4sys.Context,
    page: usize,
    runtime: *r4os.web_runtime.WebRuntime,
    next_progress: usize = 1024 * 1024,
};

const ScriptNavigation = struct {
    target: r4os.web_navigation.Url,
    scripts: usize,
    steps: usize,
};

pub fn r4_app_main(r4_app: *r4os.App) i32 {
    const sys = r4_app.system();
    var web = r4_app.web() orelse {
        sys.println("KFXLIVE result=error code=web_transport_unavailable");
        return 1;
    };
    const args = trim(zSlice(sys.argsRaw()));
    const consent_mode = startsWithIgnoreCase(args, consent_switch) and
        (args.len == consent_switch.len or isSpace(args[consent_switch.len]));
    const warmup_mode = startsWithIgnoreCase(args, warmup_switch) and
        (args.len == warmup_switch.len or isSpace(args[warmup_switch.len]));
    const page_mode = startsWithIgnoreCase(args, page_switch) and
        (args.len == page_switch.len or isSpace(args[page_switch.len]));
    const image_mode = startsWithIgnoreCase(args, image_switch) and
        (args.len == image_switch.len or isSpace(args[image_switch.len]));
    const consent_args = if (consent_mode) trim(args[consent_switch.len..]) else "";
    const warmup_args = if (warmup_mode) trim(args[warmup_switch.len..]) else "";
    const page_args = if (page_mode) trim(args[page_switch.len..]) else "";
    const image_args = if (image_mode) trim(args[image_switch.len..]) else "";
    const url = if (consent_mode)
        (if (consent_args.len == 0) default_consent_url else consent_args)
    else if (warmup_mode)
        (if (warmup_args.len == 0) default_consent_url else warmup_args)
    else if (page_mode)
        (if (page_args.len == 0) default_page_url else page_args)
    else if (image_mode)
        (if (image_args.len == 0) "https://www.w3.org/Style/Examples/007/eiffel.jpg" else image_args)
    else if (args.len == 0)
        default_url
    else
        args;
    const allocator = sys.allocator();
    const buffers = allocator.create(Buffers) catch {
        sys.println("KFXLIVE result=error code=out_of_memory");
        return 1;
    };
    sys.taskYield();
    defer allocator.destroy(buffers);
    const storage = allocator.create(r4os.web_security.BrowserStorage) catch {
        sys.println("KFXLIVE result=error code=out_of_memory");
        return 1;
    };
    sys.taskYield();
    defer allocator.destroy(storage);
    storage.* = .{};
    var cookie_context = CookieContext{ .storage = storage };
    @memset(buffers.scratch[0..], 0);

    if (warmup_mode) {
        sys.write("KFXLIVE warmup begin url=");
        sys.println(default_url);
        const warmup = web.fetch(
            default_url,
            buffers.raw[0..],
            buffers.body[0..],
            buffers.scratch[0..],
            .{
                .timeout = r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(15_000_000_000)),
                .cookie_provider = liveCookieProvider,
                .cookie_sink = liveCookieSink,
                .cookie_context = &cookie_context,
            },
        );
        switch (warmup) {
            .failure => |err| {
                sys.write("KFXLIVE warmup=error code=");
                sys.println(@tagName(err));
                return 1;
            },
            .response => |response| {
                sys.write("KFXLIVE warmup=ok status=");
                sys.printU64(response.status);
                sys.write(" bytes=");
                sys.printU64(response.body.len);
                sys.write(" cookies=");
                sys.printU64(cookieCount(storage));
                sys.println("");
                if (!response.secure or response.status < 200 or response.status >= 400 or response.body.len == 0) return 1;
            },
        }
        @memset(buffers.raw[0..], 0);
        @memset(buffers.body[0..], 0);
        @memset(buffers.scratch[0..], 0);
    }

    sys.write("KFXLIVE begin url=");
    sys.println(url);
    const result = web.fetch(
        url,
        buffers.raw[0..],
        buffers.body[0..],
        buffers.scratch[0..],
        .{
            .timeout = r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(15_000_000_000)),
            .cookie_provider = liveCookieProvider,
            .cookie_sink = liveCookieSink,
            .cookie_context = &cookie_context,
        },
    );
    switch (result) {
        .failure => |err| {
            sys.write("KFXLIVE result=error code=");
            sys.println(@tagName(err));
            printTlsEnvelopeDiagnostic(sys, buffers.scratch[tls_workspace_capacity * 2 .. tls_workspace_capacity * 3]);
            printTlsSourceDiagnostic(sys, buffers.scratch[tls_workspace_capacity .. tls_workspace_capacity * 2]);
            printTlsHandshakeDiagnostic(sys, buffers.scratch[tls_workspace_capacity .. tls_workspace_capacity * 2]);
            return 1;
        },
        .response => |response| {
            sys.write("KFXLIVE result=ok status=");
            sys.printU64(response.status);
            sys.write(" bytes=");
            sys.printU64(response.body.len);
            sys.write(" redirects=");
            sys.printU64(response.redirects);
            sys.write(" secure=");
            sys.write(if (response.secure) "yes" else "no");
            sys.write(" final=");
            sys.println(response.final_url.bytes());
            if (!response.secure or response.status < 200 or response.status >= 400 or response.body.len == 0) return 1;
            if (consent_mode) return runConsentFlow(sys, &web, allocator, buffers, storage, response);
            if (page_mode) return runPageFlow(sys, allocator, response);
            if (image_mode) {
                const images = r4img.Context.init(r4_app.startContext()) orelse {
                    sys.println("KFXLIVE image-result=error code=r4img_unavailable");
                    return 1;
                };
                return runImageFlow(sys, &images, allocator, response);
            }
            return 0;
        },
    }
}

fn runImageFlow(sys: r4os.r4sys.Context, images: *const r4img.Context, allocator: std.mem.Allocator, response: r4os.app_web.FetchResponse) i32 {
    const content_type = response.content_type orelse "";
    const info = images.probe(response.body, content_type) catch |err| {
        sys.write("KFXLIVE image-result=error code=probe_");
        sys.println(@errorName(err));
        return 1;
    };
    const pixel_count = info.pixelCount() catch |err| {
        sys.write("KFXLIVE image-result=error code=pixels_");
        sys.println(@errorName(err));
        return 1;
    };
    const scratch_size = images.scratchBytesFor(info, response.body.len) catch |err| {
        sys.write("KFXLIVE image-result=error code=scratch_");
        sys.println(@errorName(err));
        return 1;
    };
    const pixels = allocator.alloc(u32, pixel_count) catch {
        sys.println("KFXLIVE image-result=error code=pixel_allocation");
        return 1;
    };
    defer allocator.free(pixels);
    const scratch = allocator.alignedAlloc(u8, .fromByteUnits(16), scratch_size) catch {
        sys.println("KFXLIVE image-result=error code=scratch_allocation");
        return 1;
    };
    defer allocator.free(scratch);
    const decoded = images.decode(response.body, content_type, pixels, scratch) catch |err| {
        sys.write("KFXLIVE image-result=error code=decode_");
        sys.println(@errorName(err));
        printImageDecoderDiagnostic(sys, images);
        return 1;
    };

    const scaled_width: u32 = @min(info.width, 104);
    const scaled_height: u32 = @max(1, @as(u32, @intCast((@as(u64, info.height) * scaled_width) / info.width)));
    const scaled_count = std.math.mul(usize, scaled_width, scaled_height) catch {
        sys.println("KFXLIVE image-result=error code=scaled_size");
        return 1;
    };
    const scaled = allocator.alloc(u32, scaled_count) catch {
        sys.println("KFXLIVE image-result=error code=scaled_allocation");
        return 1;
    };
    defer allocator.free(scaled);
    _ = images.scaleComposite(decoded, scaled, scaled_width, scaled_height, 0x00FFFFFF) catch |err| {
        sys.write("KFXLIVE image-result=error code=scale_");
        sys.println(@errorName(err));
        return 1;
    };

    sys.write("KFXLIVE image-result=ok format=");
    sys.write(@tagName(info.format));
    sys.write(" width=");
    sys.printU64(info.width);
    sys.write(" height=");
    sys.printU64(info.height);
    sys.write(" encoded=");
    printHex64(sys, hashBytes(response.body));
    sys.write(" pixels=");
    printHex64(sys, hashPixels(decoded.pixels));
    sys.write(" first=");
    printHex64(sys, decoded.pixels[0]);
    sys.write(" center=");
    printHex64(sys, decoded.pixels[@as(usize, info.height / 2) * info.width + info.width / 2]);
    sys.write(" last=");
    printHex64(sys, decoded.pixels[decoded.pixels.len - 1]);
    sys.write(" scaled=");
    sys.printU64(scaled_width);
    sys.write("x");
    sys.printU64(scaled_height);
    sys.write(" scaled-hash=");
    printHex64(sys, hashPixels(scaled));
    sys.println("");
    printImageDecoderDiagnostic(sys, images);
    return 0;
}

fn printImageDecoderDiagnostic(sys: r4os.r4sys.Context, images: *const r4img.Context) void {
    const diagnostic = images.decoderDiagnostic() catch {
        sys.println("KFXLIVE image-decoder diagnostic=unavailable");
        return;
    };
    sys.write("KFXLIVE image-decoder scratch-peak=");
    sys.printU64(diagnostic.scratch_peak);
    sys.write(" allocation-failed=");
    sys.println(if (diagnostic.allocation_failed) "yes" else "no");
}

fn runPageFlow(sys: anytype, allocator: std.mem.Allocator, response: r4os.app_web.FetchResponse) i32 {
    const content_type = response.content_type orelse "";
    const probe = allocator.create(BrowserProbe) catch {
        sys.println("KFXLIVE page-result=error code=out_of_memory");
        return 1;
    };
    sys.taskYield();
    defer allocator.destroy(probe);
    probe.load(response.body, content_type) catch |err| {
        sys.write("KFXLIVE page-result=error code=document_");
        sys.println(@errorName(err));
        return 1;
    };

    const text = probe.visibleTextStats();
    const headings = probe.visibleHeadingCount();
    const links = probe.visibleLinkCount();
    const heading_links = probe.visibleHeadingLinkCount();
    const excerpts = probe.visibleElementCount("p");
    sys.write("KFXLIVE page-result=ok nodes=");
    sys.printU64(probe.document.node_count);
    sys.write(" layout-ops=");
    sys.printU64(probe.layout.op_count);
    sys.write(" text-ops=");
    sys.printU64(text.ops);
    sys.write(" text-bytes=");
    sys.printU64(text.bytes);
    sys.write(" headings=");
    sys.printU64(headings);
    sys.write(" visible-links=");
    sys.printU64(links);
    sys.write(" heading-links=");
    sys.printU64(heading_links);
    sys.write(" excerpts=");
    sys.printU64(excerpts);
    sys.write(" final=");
    sys.println(response.final_url.bytes());
    if (probe.document.node_count == 0 or probe.layout.op_count == 0 or text.ops == 0 or text.bytes == 0 or headings == 0 or links == 0 or heading_links == 0 or excerpts == 0) return 1;
    return 0;
}

fn runConsentFlow(
    sys: anytype,
    web: *r4os.WebTransport,
    allocator: std.mem.Allocator,
    buffers: *Buffers,
    storage: *r4os.web_security.BrowserStorage,
    response: r4os.app_web.FetchResponse,
) i32 {
    const content_type = response.content_type orelse "";
    const probe = allocator.create(BrowserProbe) catch {
        sys.println("KFXLIVE consent-result=error code=out_of_memory");
        return 1;
    };
    sys.taskYield();
    defer allocator.destroy(probe);
    probe.load(response.body, content_type) catch |err| {
        sys.write("KFXLIVE consent-result=error code=document_");
        sys.println(@errorName(err));
        return 1;
    };
    if (isDirectSearchTarget(response.final_url.bytes())) {
        sys.println("KFXLIVE direct-search-response=yes");
        return inspectConsentTarget(sys, web, allocator, probe, buffers, storage, response, 0);
    }
    const submitter = probe.firstVisibleSubmit() orelse {
        sys.println("KFXLIVE consent-result=error code=no_visible_submit");
        return 1;
    };
    const control = probe.interaction.controlForNodeConst(submitter) orelse {
        sys.println("KFXLIVE consent-result=error code=submit_control_missing");
        return 1;
    };
    sys.write("KFXLIVE consent-submit label=");
    sys.write(control.displayValue());
    sys.write(" controls=");
    sys.printU64(probe.interaction.control_count);
    sys.write(" nodes=");
    sys.printU64(probe.document.node_count);
    sys.println("");

    const base = r4os.web_navigation.parse(response.final_url.bytes()) catch {
        sys.println("KFXLIVE consent-result=error code=invalid_final_url");
        return 1;
    };
    var target_buffer: [form_target_capacity]u8 = undefined;
    var body_buffer: [form_body_capacity]u8 = undefined;
    const submission = probe.interaction.submit(
        &probe.document,
        submitter,
        &base,
        target_buffer[0..],
        body_buffer[0..],
    ) catch |err| {
        sys.write("KFXLIVE consent-result=error code=form_");
        sys.println(@errorName(err));
        return 1;
    };
    if (submission.method != .post) {
        sys.println("KFXLIVE consent-result=error code=unexpected_form_method");
        return 1;
    }
    var origin_buffer: [r4os.web_security.max_origin_host_bytes + 24]u8 = undefined;
    const source_origin = r4os.web_security.Origin.parse(response.final_url.bytes(), 1) catch {
        sys.println("KFXLIVE consent-result=error code=invalid_source_origin");
        return 1;
    };
    const origin = source_origin.serialize(origin_buffer[0..]) orelse {
        sys.println("KFXLIVE consent-result=error code=source_origin_too_long");
        return 1;
    };
    sys.write("KFXLIVE consent-request target=");
    sys.write(submission.target);
    sys.write(" body-bytes=");
    sys.printU64(submission.body.len);
    sys.write(" cookies=");
    sys.printU64(cookieCount(storage));
    sys.println("");
    var cookie_context = CookieContext{ .storage = storage };
    @memset(buffers.raw[0..], 0);
    @memset(buffers.body[0..], 0);
    const result = web.fetch(
        submission.target,
        buffers.raw[0..],
        buffers.body[0..],
        buffers.scratch[0..],
        .{
            .timeout = r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(15_000_000_000)),
            .origin = origin,
            .method = .post,
            .content_type = submission.content_type,
            .body = submission.body,
            .cookie_provider = liveCookieProvider,
            .cookie_sink = liveCookieSink,
            .cookie_context = &cookie_context,
            .redirect = .manual,
        },
    );
    switch (result) {
        .failure => |err| {
            sys.write("KFXLIVE consent-result=error code=fetch_");
            sys.println(@tagName(err));
            printHttpPrefix(sys, buffers.raw[0..]);
            return 1;
        },
        .response => |post| return finishConsentResponse(sys, web, allocator, probe, buffers, storage, post),
    }
}

fn finishConsentResponse(
    sys: anytype,
    web: *r4os.WebTransport,
    allocator: std.mem.Allocator,
    probe: *BrowserProbe,
    buffers: *Buffers,
    storage: *r4os.web_security.BrowserStorage,
    post: r4os.app_web.FetchResponse,
) i32 {
    sys.write("KFXLIVE consent-post status=");
    sys.printU64(post.status);
    sys.write(" bytes=");
    sys.printU64(post.body.len);
    sys.write(" manual=");
    sys.write(if (post.manual_redirect) "yes" else "no");
    sys.write(" cookies=");
    sys.printU64(cookieCount(storage));
    sys.println("");
    if (!post.manual_redirect) return inspectConsentTarget(sys, web, allocator, probe, buffers, storage, post, 0);

    const location = responseHeader(post.headers, "location") orelse {
        sys.println("KFXLIVE consent-result=error code=redirect_location_missing");
        return 1;
    };
    const parsed = switch (r4os.http.parseUrl(post.final_url.bytes())) {
        .value => |value| value,
        else => {
            sys.println("KFXLIVE consent-result=error code=redirect_base_invalid");
            return 1;
        },
    };
    var target_buffer: [form_target_capacity]u8 = undefined;
    const target = switch (r4os.http.resolveRedirect(parsed, location, target_buffer[0..])) {
        .url => |value| value,
        else => {
            sys.println("KFXLIVE consent-result=error code=redirect_target_invalid");
            return 1;
        },
    };
    sys.write("KFXLIVE consent-follow target=");
    sys.println(target);
    var cookie_context = CookieContext{ .storage = storage };
    var cookie_debug: [1024]u8 = undefined;
    const cookie_header = liveCookieProvider(&cookie_context, target, cookie_debug[0..]);
    sys.write("KFXLIVE consent-follow-cookie bytes=");
    sys.printU64(cookie_header.len);
    sys.write(" names=");
    printCookieNames(sys, cookie_header);
    sys.println("");
    @memset(buffers.raw[0..], 0);
    @memset(buffers.body[0..], 0);
    const follow_options = r4os.app_web.FetchOptions{
        .timeout = r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(15_000_000_000)),
        .cookie_provider = liveCookieProvider,
        .cookie_sink = liveCookieSink,
        .cookie_context = &cookie_context,
    };
    // WebTransport owns the single idempotent read retry. The live driver
    // must not multiply external requests around that policy.
    const result = web.fetch(
        target,
        buffers.raw[0..],
        buffers.body[0..],
        buffers.scratch[0..],
        follow_options,
    );
    return inspectConsentFetchResult(sys, web, allocator, probe, buffers, storage, result, 0);
}

fn inspectConsentFetchResult(
    sys: anytype,
    web: *r4os.WebTransport,
    allocator: std.mem.Allocator,
    probe: *BrowserProbe,
    buffers: *Buffers,
    storage: *r4os.web_security.BrowserStorage,
    result: r4os.app_web.FetchResult,
    script_navigations: usize,
) i32 {
    return switch (result) {
        .failure => |err| blk: {
            sys.write("KFXLIVE consent-result=error code=follow_");
            sys.println(@tagName(err));
            printHttpPrefix(sys, buffers.raw[0..]);
            break :blk 1;
        },
        .response => |final| inspectConsentTarget(sys, web, allocator, probe, buffers, storage, final, script_navigations),
    };
}

fn inspectConsentTarget(
    sys: anytype,
    web: *r4os.WebTransport,
    allocator: std.mem.Allocator,
    probe: *BrowserProbe,
    buffers: *Buffers,
    storage: *r4os.web_security.BrowserStorage,
    final: r4os.app_web.FetchResponse,
    script_navigations: usize,
) i32 {
    if (!final.secure or final.status < 200 or final.status >= 400 or final.body.len == 0) {
        sys.println("KFXLIVE consent-result=error code=invalid_final_response");
        return 1;
    }
    probe.load(final.body, final.content_type orelse "") catch |err| {
        sys.write("KFXLIVE consent-result=error code=final_document_");
        sys.println(@errorName(err));
        return 1;
    };
    const visible_links = probe.visibleLinkCount();
    const visible_heading_links = probe.visibleHeadingLinkCount();
    if (visible_heading_links > 0 and !containsIgnoreCase(final.final_url.bytes(), "consent.google.com")) {
        printConsentResult(sys, storage, final, visible_links, visible_heading_links);
        return 0;
    }

    sys.write("KFXLIVE consent-page status=");
    sys.printU64(final.status);
    sys.write(" bytes=");
    sys.printU64(final.body.len);
    sys.write(" visible-links=");
    sys.printU64(visible_links);
    sys.write(" heading-links=");
    sys.printU64(visible_heading_links);
    sys.write(" final=");
    sys.println(final.final_url.bytes());
    if (containsIgnoreCase(final.final_url.bytes(), "consent.google.com")) {
        sys.println("KFXLIVE consent-result=error code=consent_redirect_remained");
        return 1;
    }
    if (script_navigations >= max_script_navigations) {
        printConsentResult(sys, storage, final, visible_links, visible_heading_links);
        return 1;
    }

    const navigation = executePageScripts(sys, allocator, probe, storage, final, script_navigations) catch |err| {
        sys.write("KFXLIVE consent-result=error code=script_");
        sys.println(@errorName(err));
        return 1;
    };
    sys.write("KFXLIVE script-navigation scripts=");
    sys.printU64(navigation.scripts);
    sys.write(" steps=");
    sys.printU64(navigation.steps);
    sys.write(" cookies=");
    sys.printU64(cookieCount(storage));
    sys.write(" target=");
    sys.println(navigation.target.bytes());
    return followScriptNavigation(
        sys,
        web,
        allocator,
        probe,
        buffers,
        storage,
        navigation.target,
        script_navigations + 1,
    );
}

fn printConsentResult(
    sys: anytype,
    storage: *r4os.web_security.BrowserStorage,
    final: r4os.app_web.FetchResponse,
    visible_links: usize,
    visible_heading_links: usize,
) void {
    sys.write("KFXLIVE consent-result=ok status=");
    sys.printU64(final.status);
    sys.write(" bytes=");
    sys.printU64(final.body.len);
    sys.write(" redirects=");
    sys.printU64(final.redirects);
    sys.write(" cookies=");
    sys.printU64(cookieCount(storage));
    sys.write(" visible-links=");
    sys.printU64(visible_links);
    sys.write(" heading-links=");
    sys.printU64(visible_heading_links);
    sys.write(" final=");
    sys.println(final.final_url.bytes());
}

fn executePageScripts(
    sys: r4os.r4sys.Context,
    allocator: std.mem.Allocator,
    probe: *BrowserProbe,
    storage: *r4os.web_security.BrowserStorage,
    final: r4os.app_web.FetchResponse,
    page: usize,
) !ScriptNavigation {
    const runtime = try allocator.create(r4os.web_runtime.WebRuntime);
    defer allocator.destroy(runtime);
    var allocator_context = RuntimeAllocatorContext{ .allocator = allocator };
    runtime.initialize(liveProgramAllocator(&allocator_context));
    defer runtime.deinit();
    runtime.setEnvironment(.{
        .viewport_width = 940,
        .viewport_height = 480,
        .screen_width = 1024,
        .screen_height = 768,
        .online = true,
    });
    var trace_context = ScriptTraceContext{ .sys = sys, .page = page, .runtime = runtime };
    runtime.setExecutionPolicy(.{
        .context = &trace_context,
        .requested = reportScriptProgress,
        .check_interval = script_stop_check_interval,
    }, script_step_budget);
    runtime.setScriptObserver(.{ .context = &trace_context, .report = reportScriptExecution });
    runtime.setMonotonicClock(.{ .context = &trace_context, .now_milliseconds = diagnosticMonotonicNow });
    const document_now_ms = diagnosticMonotonicNow(&trace_context);
    try runtime.beginDocument(
        &probe.document,
        storage,
        final.final_url.bytes(),
        final.content_security_policy orelse "",
        1,
        document_now_ms,
    );
    sys.write("KFXLIVE script-document phase=begin page=");
    sys.printU64(page);
    sys.println("");
    const scripts = try runtime.executeDocumentScripts();
    sys.write("KFXLIVE script-document phase=finish page=");
    sys.printU64(page);
    sys.write(" scripts=");
    sys.printU64(scripts);
    sys.write(" steps=");
    sys.printU64(runtime.runtime.stats.steps);
    sys.println("");
    var target: ?r4os.web_navigation.Url = null;
    var now_ms = document_now_ms;
    runtime.markDomContentLoadedStart(now_ms);
    const dom_dispatch = try runtime.dispatchEvent(.document, "DOMContentLoaded", now_ms);
    runtime.markDomContentLoadedEnd(now_ms);
    runtime.markLoadStart(now_ms);
    const load_dispatch = try runtime.dispatchEvent(.window, "load", now_ms);
    runtime.markLoadComplete(now_ms);
    sys.write("KFXLIVE script-lifecycle page=");
    sys.printU64(page);
    sys.write(" dom-queued=");
    sys.printU64(dom_dispatch.queued);
    sys.write(" load-queued=");
    sys.printU64(load_dispatch.queued);
    sys.println("");
    var rounds: usize = 0;
    while (rounds < 1000 and target == null) : (rounds += 1) {
        now_ms += 50;
        sys.write("KFXLIVE script-pump phase=begin page=");
        sys.printU64(page);
        sys.write(" round=");
        sys.printU64(rounds);
        sys.write(" steps=");
        sys.printU64(runtime.runtime.stats.steps);
        sys.println("");
        const jobs = try runtime.pump(now_ms, 64);
        sys.write("KFXLIVE script-pump phase=finish page=");
        sys.printU64(page);
        sys.write(" round=");
        sys.printU64(rounds);
        sys.write(" jobs=");
        sys.printU64(jobs);
        sys.write(" steps=");
        sys.printU64(runtime.runtime.stats.steps);
        sys.println("");
        while (runtime.takeAction()) |action| switch (action.kind) {
            .navigate, .replace => target = action.url,
            else => {},
        };
        if (jobs == 0 and rounds > 100) break;
    }
    return .{
        .target = target orelse return error.NavigationMissing,
        .scripts = scripts,
        .steps = runtime.runtime.stats.steps,
    };
}

fn reportScriptProgress(raw_context: ?*anyopaque) bool {
    const context: *ScriptTraceContext = @ptrCast(@alignCast(raw_context orelse return false));
    const steps = context.runtime.runtime.stats.steps;
    if (steps < context.next_progress) return false;
    context.sys.write("KFXLIVE script-progress page=");
    context.sys.printU64(context.page);
    context.sys.write(" steps=");
    context.sys.printU64(steps);
    context.sys.write(" source=");
    if (context.runtime.runtime.activeProgram()) |program| {
        context.sys.write(program.sourceName());
    } else {
        context.sys.write("none");
    }
    context.sys.println("");
    context.next_progress +|= 1024 * 1024;
    return false;
}

fn diagnosticMonotonicNow(raw_context: ?*anyopaque) f64 {
    const context: *const ScriptTraceContext = @ptrCast(@alignCast(raw_context orelse return 0));
    const frequency = context.sys.monotonicHz();
    if (frequency == 0) return @floatFromInt(context.sys.ticks());
    return @as(f64, @floatFromInt(context.sys.ticks())) * 1000.0 / @as(f64, @floatFromInt(frequency));
}

fn reportScriptExecution(raw_context: ?*anyopaque, event: r4os.web_runtime.ScriptExecutionEvent) void {
    const context: *ScriptTraceContext = @ptrCast(@alignCast(raw_context orelse return));
    context.sys.write("KFXLIVE script-exec phase=");
    context.sys.write(@tagName(event.phase));
    context.sys.write(" page=");
    context.sys.printU64(context.page);
    context.sys.write(" node=");
    context.sys.printU64(event.node);
    context.sys.write(" bytes=");
    context.sys.printU64(event.source.len);
    context.sys.write(" source=");
    context.sys.write(event.source_name);
    context.sys.write(" hash=");
    printHex64(context.sys, hashBytes(event.source));
    context.sys.write(" steps=");
    context.sys.printU64(event.steps);
    context.sys.write(" success=");
    context.sys.println(if (event.success) "yes" else "no");
}

fn hashBytes(bytes: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

fn hashPixels(pixels: []const u32) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (pixels) |pixel| {
        inline for (0..4) |byte_index| {
            hash ^= @as(u8, @truncate(pixel >> @as(u5, @intCast(byte_index * 8))));
            hash *%= 0x100000001b3;
        }
    }
    return hash;
}

fn printHex64(sys: r4os.r4sys.Context, value: u64) void {
    const digits = "0123456789abcdef";
    var text: [16]u8 = undefined;
    for (0..text.len) |index| {
        const shift: u6 = @intCast((text.len - 1 - index) * 4);
        text[index] = digits[@as(usize, @intCast((value >> shift) & 0xF))];
    }
    sys.write(text[0..]);
}

fn followScriptNavigation(
    sys: anytype,
    web: *r4os.WebTransport,
    allocator: std.mem.Allocator,
    probe: *BrowserProbe,
    buffers: *Buffers,
    storage: *r4os.web_security.BrowserStorage,
    target: r4os.web_navigation.Url,
    script_navigations: usize,
) i32 {
    var cookie_context = CookieContext{ .storage = storage };
    var cookie_debug: [1024]u8 = undefined;
    const cookie_header = liveCookieProvider(&cookie_context, target.bytes(), cookie_debug[0..]);
    sys.write("KFXLIVE script-follow-cookie bytes=");
    sys.printU64(cookie_header.len);
    sys.write(" names=");
    printCookieNames(sys, cookie_header);
    sys.println("");
    @memset(buffers.raw[0..], 0);
    @memset(buffers.body[0..], 0);
    const options = r4os.app_web.FetchOptions{
        .timeout = r4os.time_contract.timeoutFinite(r4os.time_contract.durationFromNanoseconds(15_000_000_000)),
        .cookie_provider = liveCookieProvider,
        .cookie_sink = liveCookieSink,
        .cookie_context = &cookie_context,
    };
    // Script navigation uses the same transport-owned retry policy.
    const result = web.fetch(target.bytes(), buffers.raw[0..], buffers.body[0..], buffers.scratch[0..], options);
    return inspectConsentFetchResult(sys, web, allocator, probe, buffers, storage, result, script_navigations);
}

fn isHeading(name: []const u8) bool {
    return name.len == 2 and (name[0] == 'h' or name[0] == 'H') and name[1] >= '1' and name[1] <= '6';
}

fn isDirectSearchTarget(url: []const u8) bool {
    return !containsIgnoreCase(url, "consent.google.com") and containsIgnoreCase(url, "/search");
}

fn responseHeader(headers: []const u8, wanted: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), wanted)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn printHttpPrefix(sys: anytype, raw: []const u8) void {
    sys.write("KFXLIVE http-prefix=");
    var index: usize = 0;
    while (index < @min(raw.len, @as(usize, 256)) and raw[index] != 0) : (index += 1) {
        const byte = raw[index];
        const printable = if (byte >= 0x20 and byte < 0x7F) byte else '.';
        const one = [_]u8{printable};
        sys.write(one[0..]);
    }
    sys.println("");
}

fn printCookieNames(sys: anytype, header: []const u8) void {
    var cursor: usize = 0;
    var first = true;
    while (cursor < header.len) {
        while (cursor < header.len and (header[cursor] == ' ' or header[cursor] == ';')) : (cursor += 1) {}
        const start = cursor;
        while (cursor < header.len and header[cursor] != '=' and header[cursor] != ';') : (cursor += 1) {}
        if (cursor > start) {
            if (!first) sys.write(",");
            sys.write(header[start..cursor]);
            first = false;
        }
        while (cursor < header.len and header[cursor] != ';') : (cursor += 1) {}
    }
}

fn liveCookieProvider(raw_context: ?*anyopaque, url: []const u8, out: []u8) []const u8 {
    const context: *CookieContext = @ptrCast(@alignCast(raw_context orelse return ""));
    const origin = r4os.web_security.Origin.parse(url, 1) catch return "";
    return context.storage.cookies.writeRequestHeader(&origin, urlPath(url), true, out);
}

fn liveCookieSink(raw_context: ?*anyopaque, url: []const u8, header: []const u8) void {
    const context: *CookieContext = @ptrCast(@alignCast(raw_context orelse return));
    const origin = r4os.web_security.Origin.parse(url, 1) catch return;
    context.storage.cookies.setFromHeader(&origin, urlPath(url), header) catch {};
}

fn liveProgramAllocator(context: *RuntimeAllocatorContext) r4os.web_runtime.ProgramAllocator {
    return .{
        .context = context,
        .create = liveProgramCreate,
        .destroy = liveProgramDestroy,
        .allocate = liveRuntimeMemoryAllocate,
        .free = liveRuntimeMemoryFree,
    };
}

fn liveProgramCreate(raw_context: *anyopaque) ?*r4os.javascript.Program {
    const context: *RuntimeAllocatorContext = @ptrCast(@alignCast(raw_context));
    return context.allocator.create(r4os.javascript.Program) catch null;
}

fn liveProgramDestroy(raw_context: *anyopaque, program: *r4os.javascript.Program) void {
    const context: *RuntimeAllocatorContext = @ptrCast(@alignCast(raw_context));
    context.allocator.destroy(program);
}

fn liveRuntimeMemoryAllocate(raw_context: *anyopaque, length: usize, alignment: usize) ?[*]u8 {
    const context: *RuntimeAllocatorContext = @ptrCast(@alignCast(raw_context));
    return context.allocator.rawAlloc(length, .fromByteUnits(alignment), @returnAddress());
}

fn liveRuntimeMemoryFree(raw_context: *anyopaque, memory: [*]u8, length: usize, alignment: usize) void {
    const context: *RuntimeAllocatorContext = @ptrCast(@alignCast(raw_context));
    context.allocator.rawFree(memory[0..length], .fromByteUnits(alignment), @returnAddress());
}

fn urlPath(url: []const u8) []const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return "/";
    const authority_start = scheme + 3;
    const start = std.mem.indexOfScalarPos(u8, url, authority_start, '/') orelse return "/";
    const end = std.mem.indexOfAnyPos(u8, url, start, "?#") orelse url.len;
    return url[start..end];
}

fn cookieCount(storage: *const r4os.web_security.BrowserStorage) usize {
    var count: usize = 0;
    for (storage.cookies.entries) |entry| {
        if (entry.occupied) count += 1;
    }
    return count;
}

fn printTlsHandshakeDiagnostic(sys: anytype, source: []const u8) void {
    if (source.len < 5 or source[0] != 22) return;
    const record_len = readBe16(source[3..5]);
    if (record_len > source.len - 5) return;
    const fragment = source[5 .. 5 + record_len];
    var pos: usize = 0;
    while (pos + 4 <= fragment.len) {
        const body_len = readBe24(fragment[pos + 1 .. pos + 4]);
        if (body_len > fragment.len - pos - 4) return;
        sys.write("KFXLIVE tls-message type=");
        sys.printU64(fragment[pos]);
        sys.write(" bytes=");
        sys.printU64(body_len);
        sys.println("");
        if (fragment[pos] == 11 and body_len >= 3) {
            const body = fragment[pos + 4 .. pos + 4 + body_len];
            var cert_pos: usize = 3;
            var cert_index: usize = 0;
            while (cert_pos + 3 <= body.len) : (cert_index += 1) {
                const cert_len = readBe24(body[cert_pos .. cert_pos + 3]);
                cert_pos += 3;
                if (cert_len == 0 or cert_len > body.len - cert_pos) return;
                var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
                std.crypto.hash.sha2.Sha256.hash(body[cert_pos .. cert_pos + cert_len], &digest, .{});
                sys.write("KFXLIVE tls-cert index=");
                sys.printU64(cert_index);
                sys.write(" bytes=");
                sys.printU64(cert_len);
                sys.write(" sha256=");
                printHex(sys, digest[0..]);
                sys.println("");
                cert_pos += cert_len;
            }
        }
        pos += 4 + body_len;
    }
}

fn printHex(sys: anytype, bytes: []const u8) void {
    const digits = "0123456789abcdef";
    for (bytes) |byte| {
        const pair = [_]u8{ digits[byte >> 4], digits[byte & 0x0F] };
        sys.write(pair[0..]);
    }
}

fn printTlsSourceDiagnostic(sys: anytype, source: []const u8) void {
    sys.write("KFXLIVE tls-buffer-prefix=");
    var dump_index: usize = 0;
    const dump_end = @min(source.len, @as(usize, 128));
    while (dump_index < dump_end) : (dump_index += 1) {
        if (dump_index != 0) sys.write(",");
        sys.printU64(source[dump_index]);
    }
    sys.println("");
    if (source.len < 5 or source[0] != 22 or source[1] != 3) return;
    const record_len = 5 + readBe16(source[3..5]);
    const prefix_len = @min(record_len, @as(usize, 96));
    sys.write("KFXLIVE tls-source record=");
    sys.printU64(record_len);
    sys.write(" prefix=");
    var index: usize = 0;
    while (index < prefix_len and index < source.len) : (index += 1) {
        if (index != 0) sys.write(",");
        sys.printU64(source[index]);
    }
    sys.println("");
}

fn printTlsEnvelopeDiagnostic(sys: anytype, envelope: []const u8) void {
    if (envelope.len < tls_envelope_header_len) return;
    const is_begin_flight = std.mem.eql(u8, envelope[0..4], "R4CF");
    const is_finish_flight = std.mem.eql(u8, envelope[0..4], "R4CE");
    if (!is_begin_flight and !is_finish_flight) return;
    const declared_state_len = readBe32(envelope[4..8]);
    const declared_flight_len = readBe32(envelope[8..12]);
    var derived_state_len: usize = 0;
    var derived_record_len: usize = 0;
    var record_type: u8 = 0;
    var serialized_now: u64 = 0;
    if (is_begin_flight and envelope.len >= tls_envelope_header_len + tls_client_state_header_len and std.mem.eql(u8, envelope[12..16], "R4CS")) {
        const state = envelope[tls_envelope_header_len..];
        serialized_now = readBe64(state[4..12]);
        const hostname_len = readBe16(state[12..14]);
        const transcript_len_offset = 14 + tls_client_secret_len + tls_client_random_len;
        const transcript_len = readBe32(state[transcript_len_offset .. transcript_len_offset + 4]);
        derived_state_len = tls_client_state_header_len + hostname_len + transcript_len;
        const record_offset = tls_envelope_header_len + derived_state_len;
        if (record_offset + 5 <= envelope.len) {
            record_type = envelope[record_offset];
            derived_record_len = 5 + readBe16(envelope[record_offset + 3 .. record_offset + 5]);
        }
    } else if (is_finish_flight and envelope.len >= tls_envelope_header_len + tls_client_ready_header_len and std.mem.eql(u8, envelope[12..16], "R4CS")) {
        const state = envelope[tls_envelope_header_len..];
        const transcript_len = readBe32(state[4 + tls_stream_state_len .. tls_client_ready_header_len]);
        derived_state_len = tls_client_ready_header_len + transcript_len;
        const record_offset = tls_envelope_header_len + derived_state_len;
        if (record_offset + 5 <= envelope.len) {
            record_type = envelope[record_offset];
            derived_record_len = 5 + readBe16(envelope[record_offset + 3 .. record_offset + 5]);
        }
    }
    sys.write("KFXLIVE tls-envelope magic=");
    sys.write(envelope[0..4]);
    sys.write(" declared-state=");
    sys.printU64(declared_state_len);
    sys.write(" declared-flight=");
    sys.printU64(declared_flight_len);
    sys.write(" derived-state=");
    sys.printU64(derived_state_len);
    sys.write(" derived-record=");
    sys.printU64(derived_record_len);
    sys.write(" state-now=");
    sys.printU64(serialized_now);
    sys.write(" record-type=");
    sys.printU64(record_type);
    sys.write(" header=");
    var index: usize = 0;
    while (index < tls_envelope_header_len) : (index += 1) {
        if (index != 0) sys.write(",");
        sys.printU64(envelope[index]);
    }
    sys.println("");
    if (derived_state_len != 0 and derived_record_len != 0) {
        const record_offset = tls_envelope_header_len + derived_state_len;
        const prefix_len = @min(derived_record_len, @as(usize, 64));
        sys.write("KFXLIVE tls-flight-prefix=");
        index = 0;
        while (index < prefix_len and record_offset + index < envelope.len) : (index += 1) {
            if (index != 0) sys.write(",");
            sys.printU64(envelope[record_offset + index]);
        }
        sys.println("");
    }
}

fn readBe16(bytes: []const u8) usize {
    return (@as(usize, bytes[0]) << 8) | @as(usize, bytes[1]);
}

fn readBe32(bytes: []const u8) usize {
    return (@as(usize, bytes[0]) << 24) |
        (@as(usize, bytes[1]) << 16) |
        (@as(usize, bytes[2]) << 8) |
        @as(usize, bytes[3]);
}

fn readBe64(bytes: []const u8) u64 {
    var value: u64 = 0;
    for (bytes[0..8]) |byte| value = (value << 8) | byte;
    return value;
}

fn readBe24(bytes: []const u8) usize {
    return (@as(usize, bytes[0]) << 16) |
        (@as(usize, bytes[1]) << 8) |
        @as(usize, bytes[2]);
}

fn zSlice(value: [*:0]const u8) []const u8 {
    return std.mem.sliceTo(value, 0);
}

fn trim(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    return value.len >= prefix.len and std.ascii.eqlIgnoreCase(value[0..prefix.len], prefix);
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var cursor: usize = 0;
    while (cursor + needle.len <= value.len) : (cursor += 1) {
        if (std.ascii.eqlIgnoreCase(value[cursor .. cursor + needle.len], needle)) return true;
    }
    return false;
}

fn isSpace(value: u8) bool {
    return value == ' ' or value == '\t' or value == '\r' or value == '\n';
}
