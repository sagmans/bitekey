// The approved mark as data: palette, bonbon geometry and output paths. Every
// other file derives its shapes and file names from here.

import Foundation

/// Colors of the "Bonbon" sketch the owner picked. The fill is the launcher's
/// deep violet accent (`DesignTokens.Palette.appTint`, dark value), so the Dock
/// icon and the open panel read as one brand; change both together.
enum Palette {
    static let fill = RGBColor(hex: 0x3E345A)
    static let wrapper = RGBColor(hex: 0xB9A4FF)
    static let body = RGBColor(hex: 0xFF8FC2)
    static let stripe = RGBColor(hex: 0xFFF3E4)
    /// Template images carry meaning only in alpha, so the menu mark is pure black.
    static let template = RGBColor(hex: 0x000000)
}

/// The candy in the 100-unit drawing of the approved sketch; the canvas and
/// the menu mark scale it uniformly, so the approved proportions survive.
enum Bonbon {
    static let drawingSize = 100.0
    static let center = Point(x: 50, y: 50)
    /// Tilted so the candy reads as a tossed sweet, not as a flat badge.
    static let tiltDegrees = -20.0
    static let body = Ellipse(center: center, radiusX: 23, radiusY: 17)
    /// Where both wrapper ends meet the body, just inside its left edge so no gap shows.
    static let wrapperTip = Point(x: 30, y: center.y)
    /// The twisted wrapper end; the right end mirrors it across the center.
    static let wrapper = Fan(tip: wrapperTip, outerTop: Point(x: 10, y: center.y - 16), pinch: Point(x: 14, y: center.y), outerBottom: Point(x: 10, y: center.y + 16))
    /// Diagonal candy stripes; the ends sit far enough inside the body that
    /// the round caps stay on the candy. `checkStripesInsideBody` enforces it.
    static let stripes = [
        Segment(from: Point(x: 40, y: 38), to: Point(x: 48, y: 63)),
        Segment(from: Point(x: 50, y: 37), to: Point(x: 59, y: 62)),
        Segment(from: Point(x: 61, y: 39), to: Point(x: 66, y: 56)),
    ]
    static let stripeWidth = 4.0
    /// Points tested on each cap circle; enough that a gap between samples
    /// cannot hide a visible overhang at the 1024 px canvas.
    static let capSamples = 64
    /// Highest normalized ellipse value a cap point may reach. Below 1, so a
    /// cap never shares the body's antialiased edge pixel and float rounding
    /// cannot flip the check.
    static let capEllipseLimit = 0.95

    /// Fails the run when a stripe would draw past the body. A round-capped
    /// stroke is the convex hull of its two end discs, and the body is
    /// convex, so checking both end discs covers the whole stripe.
    static func checkStripesInsideBody(path: String) throws {
        let radius = stripeWidth / 2
        for (index, stripe) in stripes.enumerated() {
            for end in [stripe.from, stripe.to] {
                for sample in 0 ..< capSamples {
                    let angle = 2 * Double.pi * Double(sample) / Double(capSamples)
                    let edge = Point(x: end.x + radius * cos(angle), y: end.y + radius * sin(angle))
                    guard body.normalizedDistance(to: edge) <= capEllipseLimit else {
                        throw RenderFailure.invalidOutput(path: path, reason: "stripe \(index) cap at (\(end.x), \(end.y)) reaches (\(edge.x), \(edge.y)), too close to or outside the body edge (limit \(capEllipseLimit)); move that end inward.")
                    }
                }
            }
        }
    }
}

/// The menu mark: a solid silhouette with wider wrapper ends and a rounder
/// body and no stripes, because stripes blur into noise at 18 px.
enum MenuMark {
    /// The menu SVG is authored in the drawing's own units.
    static let scale = 1.0
    static let body = Ellipse(center: Bonbon.center, radiusX: 25, radiusY: 19)
    static let wrapper = Fan(tip: Bonbon.wrapperTip, outerTop: Point(x: 6, y: Bonbon.center.y - 20), pinch: Point(x: 12, y: Bonbon.center.y), outerBottom: Point(x: 6, y: Bonbon.center.y + 20))
}

/// The `.icon` canvas; the drawing fills it edge to edge, because macOS draws
/// its own squircle and glass around the solid fill.
enum Canvas {
    static let size = 1024.0
    /// Derived from the drawing, so the canvas follows it if the drawing size changes.
    static let scale = size / Bonbon.drawingSize
}

/// Output locations, relative to the repository root.
enum OutputPath {
    static let iconManifest = "Resources/AppIcon.icon/icon.json"
    static let assetsDirectory = "Resources/AppIcon.icon/Assets"
    static let menuSource = "Resources/Icon/MenuBarIcon.svg"
    static let iconDocument = "Resources/AppIcon.icon"
    /// Source of truth for the minimum macOS version, so actool targets what the app claims.
    static let infoPlist = "Resources/Info.plist"
    /// The only area the catalog command may clear; it is ignored by version control.
    static let buildDirectory = ".build"
    /// AppKit picks the @2x file on Retina screens; the names are what the app loads.
    static let menuTemplate = "Resources/MenuBarIconTemplate.png"
    static let menuTemplateRetina = "Resources/MenuBarIconTemplate@2x.png"
    /// Repository brand image (social preview); it shows the same glass art the Dock does.
    static let logo = "Resources/Logo.png"
    /// Shipped instead of `actool`'s `.icns`, which stops at 256 px and is too small for the dmg.
    static let appIcon = "Resources/AppIcon.icns"
}

/// Layers of the `.icon` bundle, declared in paint order, bottom first. Each
/// candy part is its own layer, so the macOS glass gives every part depth.
enum IconLayer: String, CaseIterable {
    case wrapper = "Wrapper"
    case body = "Body"
    case stripes = "Stripes"

    /// Icon Composer lists layers top first; a probe with `ictool` hid upper
    /// layers under lower ones when they were listed bottom first.
    static var manifestOrder: [IconLayer] {
        allCases.reversed()
    }

    /// File name inside `Assets`, which is also the manifest's `image-name`.
    var fileName: String {
        "\(rawValue).svg"
    }

    /// Repository path for `Writer`.
    var path: String {
        "\(OutputPath.assetsDirectory)/\(fileName)"
    }

    /// An exhaustive switch makes a new layer fail to compile until it has artwork.
    var svg: String {
        switch self {
        case .wrapper: canvasLayerSVG(wrapperSVG(Bonbon.wrapper, color: Palette.wrapper))
        case .body: canvasLayerSVG(ellipseSVG(Bonbon.body, color: Palette.body))
        case .stripes: canvasLayerSVG(stripesSVG(Bonbon.stripes, width: Bonbon.stripeWidth, color: Palette.stripe))
        }
    }
}

/// `icon.json` values probed against `ictool` and `actool` on Xcode 27.2.
enum IconManifest {
    static let platform = "macOS"
    static let colorSpace = "srgb"
    static let componentDigits = 5
    static let alpha = 1.0
}

/// SVG text settings; fixed precision keeps reruns byte-identical.
enum SVGFormat {
    static let namespace = "http://www.w3.org/2000/svg"
    static let fractionDigits = 3
}

/// One color, kept as 8-bit channels so SVG hex and manifest components agree exactly.
struct RGBColor {
    private static let channelMax = 255.0
    private static let redShift = 16
    private static let greenShift = 8
    private static let channelMask = 0xFF

    let red: Int
    let green: Int
    let blue: Int

    /// Hex literals match how the palette was approved and reviewed.
    init(hex: Int) {
        red = (hex >> Self.redShift) & Self.channelMask
        green = (hex >> Self.greenShift) & Self.channelMask
        blue = hex & Self.channelMask
    }

    /// Lowercase `#rrggbb`, so reruns emit identical text.
    var svg: String {
        String(format: "#%02x%02x%02x", red, green, blue)
    }

    /// Icon Composer stores color as unit components, not hex.
    func manifest(digits: Int) -> String {
        [red, green, blue].map { String(format: "%.\(digits)f", Double($0) / Self.channelMax) }.joined(separator: ",")
    }
}

/// A point in drawing units.
struct Point {
    let x: Double
    let y: Double

    /// The right wrapper end is the left one reflected across the candy's vertical axis.
    func mirrored(acrossX axis: Double) -> Point {
        Point(x: 2 * axis - x, y: y)
    }
}

/// The candy body.
struct Ellipse {
    let center: Point
    let radiusX: Double
    let radiusY: Double

    /// The menu-bar floor check measures the mark against this area.
    var area: Double {
        Double.pi * radiusX * radiusY
    }

    /// 1 on the outline, below 1 inside; the stripe check compares it with a
    /// limit so caps keep clear of the body edge.
    func normalizedDistance(to point: Point) -> Double {
        let dx = (point.x - center.x) / radiusX
        let dy = (point.y - center.y) / radiusY
        return dx * dx + dy * dy
    }
}

/// A twisted wrapper end: straight edges from the tip, closed by a curve
/// that bows in toward the pinch, so the paper looks gathered.
struct Fan {
    let tip: Point
    let outerTop: Point
    let pinch: Point
    let outerBottom: Point

    /// Builds the opposite end, so both ends always match.
    func mirrored(acrossX axis: Double) -> Fan {
        Fan(tip: tip.mirrored(acrossX: axis), outerTop: outerTop.mirrored(acrossX: axis), pinch: pinch.mirrored(acrossX: axis), outerBottom: outerBottom.mirrored(acrossX: axis))
    }
}

/// One stripe, drawn with round caps.
struct Segment {
    let from: Point
    let to: Point
}
