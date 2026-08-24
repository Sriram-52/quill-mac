// Renders the Quill app icon to assets/icon_1024.png.
// Run from the repo root:  swift scripts/render-icon.swift
import SwiftUI
import AppKit

struct QuillIcon: View {
    var body: some View {
        ZStack {
            // Ink-dark squircle
            RoundedRectangle(cornerRadius: 224, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.165, green: 0.196, blue: 0.271),
                                 Color(red: 0.070, green: 0.086, blue: 0.122)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 224, style: .continuous)
                        .fill(
                            RadialGradient(
                                colors: [Color.white.opacity(0.10), .clear],
                                center: UnitPoint(x: 0.5, y: 0.24),
                                startRadius: 0, endRadius: 620
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 224, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 6)
                )

            // Q ring
            Circle()
                .stroke(Color(red: 0.96, green: 0.97, blue: 0.99), lineWidth: 72)
                .frame(width: 410, height: 410)
                .position(x: 512, y: 430)

            // Pen-nib tail
            Path { p in
                p.move(to: CGPoint(x: 596, y: 622))
                p.addQuadCurve(to: CGPoint(x: 792, y: 700), control: CGPoint(x: 700, y: 694))
                p.addQuadCurve(to: CGPoint(x: 676, y: 542), control: CGPoint(x: 748, y: 592))
                p.closeSubpath()
            }
            .fill(Color(red: 0.96, green: 0.97, blue: 0.99))

            // Green grammar squiggle
            Path { p in
                let x0 = 288.0, x1 = 736.0, midY = 822.0, amp = 30.0, periods = 2.5
                p.move(to: CGPoint(x: x0, y: midY))
                let steps = 120
                for i in 1...steps {
                    let t = Double(i) / Double(steps)
                    let x = x0 + (x1 - x0) * t
                    let y = midY + amp * sin(t * periods * 2 * .pi)
                    p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(
                LinearGradient(
                    colors: [Color(red: 0.24, green: 0.86, blue: 0.59),
                             Color(red: 0.05, green: 0.62, blue: 0.43)],
                    startPoint: .leading, endPoint: .trailing
                ),
                style: StrokeStyle(lineWidth: 42, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(width: 1024, height: 1024)
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: QuillIcon())
    renderer.scale = 1
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("render failed")
    }
    try! FileManager.default.createDirectory(atPath: "assets", withIntermediateDirectories: true)
    try! png.write(to: URL(fileURLWithPath: "assets/icon_1024.png"))
    print("Wrote assets/icon_1024.png")
}
