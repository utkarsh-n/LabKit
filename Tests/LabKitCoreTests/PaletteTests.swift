import XCTest

@testable import LabKitCore

/// Palette rules of labkit-from-orbitals-spectra.md §2.3–§2.4, as tests.
final class PaletteTests: XCTestCase {
  static let palettes: [LabPalette] = [.orbitals, .gyre, .tether, .spectra, .rheo]

  /// Every text token reaches WCAG AA (4.5:1) on every surface of every ground.
  func testTextContrastOnAllGrounds() {
    for ground in LabGround.all {
      for surface in [ground.background, ground.panel, ground.plot, ground.stage] {
        let checks: [(String, LabColor)] = [
          ("ink", .white),
          ("body", LabColor.white.over(surface, alpha: LabSemantic.bodyAlpha)),
          ("secondary", LabColor.white.over(surface, alpha: LabSemantic.secondaryAlpha)),
          ("tertiary", LabColor.white.over(surface, alpha: LabSemantic.tertiaryAlpha)),
          ("muted", ground.muted), ("dim", ground.dim),
          ("live", LabSemantic.live), ("value", LabSemantic.value), ("warning", LabSemantic.warning),
          ("forecast", LabSemantic.forecast), ("simulated", LabSemantic.simulated),
        ]
        for (name, c) in checks {
          XCTAssertGreaterThanOrEqual(c.contrast(against: surface), 4.5, "\(name) on \(ground.name) \(surface.hex)")
        }
      }
    }
  }

  func testSignatureParameterAndDataHuesReadOnPanels() {
    for p in Self.palettes {
      let panel = p.ground.panel
      XCTAssertGreaterThanOrEqual(p.signature.contrast(against: panel), 4.5, p.app)
      for (id, hue) in p.parameterHues {
        XCTAssertGreaterThanOrEqual(hue.contrast(against: panel), 4.5, "\(p.app).\(id)")
      }
      for d in p.dataHues {
        XCTAssertGreaterThanOrEqual(d.colour.contrast(against: panel), 3.0, "\(p.app) data \(d.id)")
      }
      XCTAssertGreaterThanOrEqual(p.onSignature.contrast(against: p.signature), 4.5, "\(p.app) onSignature")
      XCTAssertGreaterThanOrEqual(LabColor.white.contrast(against: p.signatureDeep), 4.49, "\(p.app) signatureDeep")
    }
    // White on Rheo's pink fails (2.90:1), so the label is the ground and system fills use the deep tint.
    XCTAssertEqual(LabColor.white.contrast(against: LabPalette.rheo.signature), 2.90, accuracy: 0.01)
    XCTAssertEqual(LabPalette.rheo.onSignature, LabGround.abyss.background)
    let deep = LabPalette.rheo.signatureDeep
    XCTAssertEqual(deep.r, 0.790, accuracy: 0.002)
    XCTAssertEqual(deep.g, 0.270, accuracy: 0.002)
    XCTAssertEqual(deep.b, 0.510, accuracy: 0.002)
  }

  /// Rheo's knob hues all read ≥ 7:1 on its panel (§2.4).
  func testRheoParameterHuesAreBright() {
    for (id, hue) in LabPalette.rheo.parameterHues {
      XCTAssertGreaterThanOrEqual(hue.contrast(against: LabGround.abyss.panel), 7.0, id.rawValue)
    }
  }

  /// Orbitals' rule: parameter identity and data identity never share a hue (OKLab ≥ 0.10).
  func testParameterAndDataHuesAreDistinct() {
    for p in Self.palettes where p.app != "Spectra" {
      for (id, hue) in p.parameterHues {
        for d in p.dataHues {
          XCTAssertGreaterThanOrEqual(hue.perceptualDistance(to: d.colour), 0.10, "\(p.app) \(id) vs \(d.id)")
        }
      }
    }
    // Known clash flagged for the Spectra port (§2.4): δ rose equals source B.
    XCTAssertEqual(LabPalette.spectra.hue(for: "delta"), LabPalette.spectra.data("b"))
  }

  /// Knobs that share a console page (or the Rheometer sheet) are told apart by hue; the signature is not a knob hue.
  func testRheoPagesAndSignatureAreDistinct() {
    let p = LabPalette.rheo
    for page in LabPalette.rheoPageGroups {
      for (i, a) in page.enumerated() {
        for b in page[(i + 1)...] {
          // Rule ≥ 0.08 (aim 0.12); the Rheo set measures ≥ 0.1149 (Signals: Gain vs Band).
          XCTAssertGreaterThanOrEqual(p.hue(for: a).perceptualDistance(to: p.hue(for: b)), 0.114, "\(a) vs \(b)")
        }
      }
    }
    for (id, hue) in p.parameterHues {
      XCTAssertGreaterThanOrEqual(p.signature.perceptualDistance(to: hue), 0.10, "signature vs \(id)")
    }
    // Every Rheo knob in the page groups has its own hue (none falls back to the signature).
    for id in LabPalette.rheoPageGroups.joined() { XCTAssertNotNil(p.parameterHues[id], id.rawValue) }
  }

  /// Shared quantities keep their Gyre hue in every app.
  func testSharedHuesAreConsistent() {
    for id: ParamID in ["gravity", "magnet", "time", "listen", "drives", "gain"] {
      XCTAssertEqual(LabPalette.rheo.hue(for: id), LabPalette.sharedHues[id], id.rawValue)
      XCTAssertEqual(LabPalette.gyre.hue(for: id), LabPalette.sharedHues[id], id.rawValue)
    }
    XCTAssertEqual(LabPalette.orbitals.hue(for: "gravity"), LabPalette.sharedHues["gravity"])
    XCTAssertEqual(LabPalette.orbitals.hue(for: "nonexistent"), LabPalette.orbitals.signature)
  }

  /// Cross-page near-duplicates are allowed but listed, so a new knob can't quietly add a same-page clash.
  func testKnownCrossPageNearDuplicatesAreTheOnlyOnes() {
    let p = LabPalette.rheo
    let ids = p.parameterHues.keys.sorted()
    var close: Set<String> = []
    for (i, a) in ids.enumerated() {
      for b in ids[(i + 1)...] where p.hue(for: a).perceptualDistance(to: p.hue(for: b)) < 0.05 {
        close.insert("\(a)-\(b)")
      }
    }
    // All cross-page (none share a console page or the Rheometer sheet); titles and icons tell them apart.
    XCTAssertEqual(
      close,
      ["consistency-gain", "magnet-rebuild", "rebuild-tracers", "magnet-tracers", "listen-magnet", "index-time",
       "finger-gain"])
  }

  /// The 13 Rheo fluids: ids match ContinuumPresets names, and the documented near-twins are the only ones.
  func testRheoFluids() {
    let ids = LabPalette.rheoFluids.map(\.id)
    XCTAssertEqual(ids.count, 13)
    XCTAssertEqual(Set(ids).count, 13)
    XCTAssertEqual(
      Set(ids),
      ["waterLike", "honey", "ketchup", "mayonnaise", "toothpaste", "oobleck", "slime", "sillyPutty", "yogurt",
       "quicksand", "mrFluid", "paint", "lava"])
    var twins: Set<String> = []
    for (i, a) in LabPalette.rheoFluids.enumerated() {
      for b in LabPalette.rheoFluids[(i + 1)...] where a.colour.perceptualDistance(to: b.colour) < 0.08 {
        twins.insert("\(a.id)-\(b.id)")
      }
    }
    XCTAssertEqual(twins, ["oobleck-mayonnaise", "oobleck-yogurt", "mayonnaise-yogurt", "ketchup-lava"])
    XCTAssertEqual(LabPalette.rheo.data("oobleck"), LabColor(0.93, 0.92, 0.86))
    XCTAssertEqual(LabPalette.rheo.data("unknown"), LabPalette.rheo.signature)
  }

  func testColourConversions() {
    XCTAssertEqual(LabColor.white.linearSRGB, SIMD3(1, 1, 1))
    XCTAssertEqual(Double(LabColor(0.5, 0.5, 0.5).linearSRGB.x), 0.214, accuracy: 0.001)
    let p3 = LabColor.white.linearDisplayP3
    XCTAssertEqual(Double(p3.x), 1, accuracy: 1e-5)
    XCTAssertEqual(Double(p3.y), 1, accuracy: 1e-5)
    XCTAssertEqual(Double(p3.z), 1, accuracy: 1e-5)
    // Pure sRGB red is inside P3: less red, a little green and blue in P3 coordinates.
    let red = LabColor(1, 0, 0).linearDisplayP3
    XCTAssertEqual(Double(red.x), 0.822462, accuracy: 1e-5)
    XCTAssertEqual(LabColor(hex: "#ff8f6b"), LabColor(1, 143.0 / 255, 107.0 / 255))
    XCTAssertEqual(LabColor(hex: "#FF8F6B").hex, "#FF8F6B")
    XCTAssertEqual(LabColor(hex: "nonsense"), .black)
    XCTAssertEqual(LabColor.white.contrast(against: .black), 21, accuracy: 1e-9)
    XCTAssertEqual(LabColor.encode(LabColor.decode(0.37)), 0.37, accuracy: 1e-12)
    // Gyre's legend painted HoloPalette's *linear* 0.30 as sRGB: encoded it is 0.584, so its swatch was too dark.
    XCTAssertEqual(LabColor.encode(0.30), 0.584, accuracy: 0.002)
  }

  func testCodableRoundTrip() throws {
    let data = try JSONEncoder().encode(LabGround.abyss)
    XCTAssertEqual(try JSONDecoder().decode(LabGround.self, from: data), .abyss)
  }
}
