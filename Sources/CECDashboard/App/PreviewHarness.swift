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

    static let views: [String: @MainActor () -> AnyView] = [
        "leads":        { AnyView(ABLeadsView(data: .ab, interactionDemo: false, staticRender: true)) },
        // interaction-demo variant: pressed hero card + hovered recent row +
        // hovered "Replied" status bar — proves hover/press states in a still.
        "leads-detail": { AnyView(ABLeadsView(data: .ab, interactionDemo: true, staticRender: true)) },
    ]
}

@MainActor
enum PreviewHarness {
    private static let MAX_RENDER_PIXELS = 8192

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
        let content = builder()
            .frame(width: PreviewRegistry.canvas.width, height: PreviewRegistry.canvas.height,
                   alignment: .top)   // top-align so tall content overflows only at the bottom
            .environment(\.colorScheme, dark ? .dark : .light)
        let ns = NSAppearance(named: dark ? .darkAqua : .aqua)

        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(PreviewRegistry.canvas)

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
