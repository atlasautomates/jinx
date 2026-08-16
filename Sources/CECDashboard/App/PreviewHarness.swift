import AppKit
import SwiftUI

// Preview harness (bible §9 / preview-harness.md contract). Renders a registered
// view to a deterministic PNG via ImageRenderer — offscreen, no TCC, no network,
// no Supabase. Intercepted in App.init() BEFORE any store/subsystem boots, then
// exits unconditionally (same shape as the --query pre-boot intercept).
//
//   CECDashboard --screenshot <view> [--out <path>] [--scale 2] [--appearance dark]
//   CECDashboard --screenshot list
//
// Exit: 0 ok · 1 bad args (unknown view / bad flag) · 2 render/write failure.

@MainActor
enum PreviewRegistry {
    // Fixed logical canvas for the A/B comparison.
    static let canvas = CGSize(width: 1440, height: 1000)

    /// Views that are not tab stills and need their own canvas.
    static let canvases: [String: CGSize] = [
        // Apple's macOS icon grid.
        "app-icon": CGSize(width: AppIconArt.canvas, height: AppIconArt.canvas),
    ]

    static func canvas(for view: String) -> CGSize { canvases[view] ?? canvas }

    static let views: [String: @MainActor () -> AnyView] = [
        "leads":        { AnyView(ABLeadsView(data: .ab, interactionDemo: false, staticRender: true)) },
        // interaction-demo variant: pressed hero card + hovered recent row +
        // hovered "Replied" status bar — proves hover/press states in a still.
        "leads-detail": { AnyView(ABLeadsView(data: .ab, interactionDemo: true, staticRender: true)) },
        // Filter bar in its ACTIVE state: two dimensions set, and every figure on
        // the tab computed from that narrowed set (the feature's whole claim).
        // The bar's pills read the REQUESTED filter (a separate input from the data,
        // so a view can't mistake it for what was applied) — a still must pass it or
        // it shows unlit pills above a caption saying the view is filtered.
        "leads-filtered": { AnyView(ABLeadsView(data: .abFiltered, staticRender: true,
                                                requestedFilter: ABLeadsData.abFiltered.effectiveFilter)) },
        // Search results owning the list column, with the box carrying its term.
        "leads-search":   { AnyView(ABLeadsView(
            data: .ab, staticRender: true,
            searchQuery: .constant("harbor"),
            searchState: .results(term: "harbor", hits: Array(ABLeadsData.ab.recentLeads.prefix(3)),
                                  hiddenByFilter: 0))) },
        // The three states nobody looks at unless they are registered: a search that
        // found nothing, one that FAILED (must not read as "no such lead"), and a
        // degraded load naming which figures are understated.
        "leads-search-empty": { AnyView(ABLeadsView(
            data: .ab, staticRender: true,
            searchQuery: .constant("zzzz"),
            searchState: .results(term: "zzzz", hits: [], hiddenByFilter: 0))) },
        "leads-search-failed": { AnyView(ABLeadsView(
            data: .ab, staticRender: true,
            searchQuery: .constant("harbor"),
            searchState: .failed(term: "harbor",
                                 message: "Network error: The request timed out."))) },
        "leads-degraded": { AnyView(ABLeadsView(data: .abDegraded, staticRender: true)) },
        // Search results NARROWED by the active filter, with the hits it removed
        // counted and offered — a hidden lead must never read as a missing one.
        "leads-search-scoped": { AnyView(ABLeadsView(
            data: .abFiltered, staticRender: true,
            requestedFilter: ABLeadsData.abFiltered.effectiveFilter,
            searchQuery: .constant("solar"),
            searchState: .results(term: "solar",
                                  hits: Array(ABLeadsData.ab.recentLeads.prefix(2)),
                                  hiddenByFilter: 7),
            onToggleSearchFilters: { _ in })) },
        // Lead dossier at rest, then with the click-to-copy affordance forced:
        // Industry hovered (glyph + lifted surface), Email just copied.
        // The app icon, rendered through the app's own tokens (see AppIconArt) so it
        // cannot drift from the palette the UI uses.
        "app-icon":     { AnyView(AppIconArt()) },
        "profile":      { AnyView(LeadProfileFixture.view()) },
        "profile-copy": { AnyView(LeadProfileFixture.view(
            demo: LeadProfileFixture.copyDemo)) },
        // (The campaigns/pipeline stills left with their tabs — 7.2 deprecation.)
    ]
}

/// Deliberately ungated AppKit view — the placeholder detector's positive
/// control. `ImageRenderer` cannot rasterize it, which is exactly the point.
private struct UngatedAppKitProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
enum PreviewHarness {
    private static let MAX_RENDER_PIXELS = 8192

    /// SwiftUI's "unsupported view" placeholder — the opaque yellow block
    /// ImageRenderer paints where an `NSViewRepresentable` should be. Sampled
    /// from a real placeholder render; nothing in the palette comes near it.
    static let placeholderYellow = (r: 255, g: 204, b: 0)

    /// A clean render scores EXACTLY 0, so any hit at all is a real placeholder.
    /// A slack threshold defeats the guard: a small ungated control (the ~16pt
    /// opener/offer copy glyphs) scores ~100, which a threshold of 200 waved
    /// through. Small headroom only, for anti-aliasing.
    static let placeholderTolerance = 8

    /// Renders one registry view and counts placeholder-yellow pixels.
    ///
    /// This is the deterministic pin behind `\.isStaticRender`: an AppKit-backed
    /// child added to a previewable view destroys every still it appears in, and
    /// nothing else notices — `--selftest` passes and `--screenshot` exits 0
    /// while painting a yellow block over the content. `--selftest` calls this
    /// for every registered view so the class fails loudly instead.
    static func placeholderPixels(in view: String) -> Int? {
        guard let builder = PreviewRegistry.views[view] else { return nil }
        return placeholderPixels(rendering: AnyView(builder()),
                                 canvas: PreviewRegistry.canvas(for: view))
    }

    /// Positive control: a deliberately UNGATED `NSViewRepresentable` must score
    /// above the threshold. Without this, "0 hits" conflates *clean* with
    /// *detector blind* — if a future macOS changes the placeholder shade, every
    /// view silently scores 0 and the guard is dead with the suite green.
    static func detectorControlPixels() -> Int? {
        placeholderPixels(rendering: AnyView(
            UngatedAppKitProbe().frame(width: 120, height: 120)),
            canvas: PreviewRegistry.canvas)
    }

    // `canvas` has NO default: a default-argument expression is evaluated
    // nonisolated, so reading @MainActor state there is a Swift 6 error.
    private static func placeholderPixels(rendering view: AnyView, canvas: CGSize) -> Int? {
        let content = view
            .frame(width: canvas.width, height: canvas.height, alignment: .top)
            .environment(\.colorScheme, .dark)
            .environment(\.isStaticRender, true)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(canvas)
        var cg: CGImage?
        if let ns = NSAppearance(named: .darkAqua) {
            ns.performAsCurrentDrawingAppearance { cg = renderer.cgImage }
        } else {
            cg = renderer.cgImage
        }
        guard let image = cg else { return nil }

        // Redraw into a canonical sRGB RGBA8 buffer rather than scanning the
        // rep as it comes back. ImageRenderer's format is CONTENT-dependent: a
        // view with extended-range colour returns 64bpp half-float samples, and
        // a byte-wise scan of that reads the low/high bytes of R and the low
        // byte of G as R/G/B — it can never match, so it returns 0, which reads
        // as "clean" and silently disables the guard for that view. (Real case:
        // `leads-detail` renders at 64bpp; an injected placeholder scored 9428
        // on `profile` and 0 there.) Normalizing also pins the comparison to
        // sRGB, the space the reference colour was sampled in.
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }

        var hits = 0
        for p in stride(from: 0, to: buf.count, by: 4) {
            if abs(Int(buf[p]) - placeholderYellow.r) <= 6,
               abs(Int(buf[p + 1]) - placeholderYellow.g) <= 6,
               abs(Int(buf[p + 2]) - placeholderYellow.b) <= 6 { hits += 1 }
        }
        return hits
    }

    /// Call from App.init(). Returns only if `--screenshot` was not requested.
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshot") else { return }
        let view = (i + 1 < args.count) ? args[i + 1] : ""
        run(view: view)   // never returns
    }

    private static func argValue(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static func fail(_ msg: String, _ code: Int32) -> Never {
        FileHandle.standardError.write(Data((msg + "\n").utf8))
        exit(code)
    }

    private static func run(view: String) -> Never {
        if view == "list" {
            let names = PreviewRegistry.views.keys.sorted().joined(separator: "\n")
            FileHandle.standardOutput.write(Data((names + "\n").utf8))
            exit(0)
        }
        guard let builder = PreviewRegistry.views[view] else {
            let valid = PreviewRegistry.views.keys.sorted().joined(separator: ", ")
            fail("ERROR: unknown view \(view.isEmpty ? "(none)" : "'\(view)'"). Valid: \(valid), list", 1)
        }

        let scale = Double(argValue("--scale") ?? "2") ?? 2.0
        guard scale > 0, scale <= 4 else { fail("ERROR: --scale must be in (0, 4]", 1) }
        let appearance = (argValue("--appearance") ?? "dark").lowercased()
        guard appearance == "dark" || appearance == "light" else {
            fail("ERROR: --appearance must be dark|light", 1)
        }
        let dark = appearance == "dark"

        let outPath = argValue("--out") ?? defaultOut(for: view)
        guard let outPath else {
            fail("ERROR: could not locate repo root for default --out; pass --out <path>", 1)
        }

        // Pin appearance at BOTH layers (SwiftUI colorScheme + NSAppearance) and
        // give the view an explicit frame so it can't collapse to its ideal size.
        let size = PreviewRegistry.canvas(for: view)
        let content = builder()
            .frame(width: size.width, height: size.height,
                   alignment: .top)   // top-align so tall content overflows only at the bottom
            .environment(\.colorScheme, dark ? .dark : .light)
            // Applies to EVERY registry entry — this is the one place that knows
            // it's a still render. AppKit-backed children gate themselves off it
            // (ImageRenderer paints a yellow placeholder over them instead).
            .environment(\.isStaticRender, true)
        let ns = NSAppearance(named: dark ? .darkAqua : .aqua)

        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)

        var cg: CGImage?
        if let ns {
            ns.performAsCurrentDrawingAppearance { cg = renderer.cgImage }
        } else {
            cg = renderer.cgImage
        }
        guard let image = cg else { fail("ERROR: ImageRenderer produced no image", 2) }

        let rep = NSBitmapImageRep(cgImage: image)
        if rep.pixelsWide > MAX_RENDER_PIXELS || rep.pixelsHigh > MAX_RENDER_PIXELS {
            fail("ERROR: render \(rep.pixelsWide)x\(rep.pixelsHigh)px exceeds \(MAX_RENDER_PIXELS)px cap", 2)
        }
        // Pin output profile to sRGB (unpinned, offscreen renders drift P3 vs sRGB).
        let srgb = (rep.colorSpace == .sRGB) ? rep
            : (rep.converting(to: .sRGB, renderingIntent: .relativeColorimetric) ?? rep)
        guard let data = srgb.representation(using: .png, properties: [:]) else {
            fail("ERROR: PNG encode failed", 2)
        }
        do {
            let url = URL(fileURLWithPath: outPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            fail("ERROR: PNG write failed: \(error)", 2)
        }
        FileHandle.standardOutput.write(Data((URL(fileURLWithPath: outPath).path + "\n").utf8))
        exit(0)
    }

    /// Default output resolved against the repo root (an installed binary has
    /// cwd "/"). Walks up from cwd and the executable dir looking for the AB-ARM
    /// marker; returns nil if not found (caller then requires --out).
    private static func defaultOut(for view: String) -> String? {
        guard let root = repoRoot() else { return nil }
        return root.appendingPathComponent("AB-ARM/previews/\(view).png").path
    }

    private static func repoRoot() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = [URL(fileURLWithPath: fm.currentDirectoryPath)]
        candidates.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent())
        for start in candidates {
            var dir = start
            for _ in 0..<12 {
                if fm.fileExists(atPath: dir.appendingPathComponent("AB-ARM").path) { return dir }
                let parent = dir.deletingLastPathComponent()
                if parent.path == dir.path { break }
                dir = parent
            }
        }
        return nil
    }
}
