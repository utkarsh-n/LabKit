import Foundation

/// Copy checks an app runs in its unit tests (labkit-from-orbitals-spectra.md §7.1, §7.5 rule 5):
/// British spelling, and UI named by its live labels.
public enum CopyLint {
  /// American spellings from the house word list, with the British form to use.
  public static let britishSpellings: [String: String] = [
    "color": "colour", "colors": "colours", "colored": "coloured", "center": "centre", "centered": "centred",
    "centers": "centres", "analyze": "analyse", "analyzed": "analysed", "recognize": "recognise",
    "recognized": "recognised", "visualize": "visualise", "visualization": "visualisation",
    "behavior": "behaviour", "behaviors": "behaviours", "modeled": "modelled", "modeling": "modelling",
    "labeled": "labelled", "labeling": "labelling", "traveled": "travelled", "traveling": "travelling",
    "gray": "grey", "mold": "mould", "skeptical": "sceptical", "fiber": "fibre", "fibers": "fibres",
    "favorite": "favourite", "flavor": "flavour", "neighbor": "neighbour", "optimize": "optimise",
    "liter": "litre", "liters": "litres", "millimeter": "millimetre", "millimeters": "millimetres",
    "centimeter": "centimetre", "centimeters": "centimetres", "kilometer": "kilometre",
    "catalog": "catalogue", "dialog": "dialogue", "realize": "realise", "realized": "realised",
    "organize": "organise", "minimize": "minimise", "maximize": "maximise", "stabilize": "stabilise",
    "magnetize": "magnetise", "magnetized": "magnetised", "vaporize": "vaporise", "jewelry": "jewellery",
    "aluminum": "aluminium", "defense": "defence",
  ]

  /// Words in `text` that use American spelling, lowercased, in order of appearance.
  /// "meter" alone is not flagged: it is right for instruments ("level meter").
  public static func americanSpellings(in text: String) -> [String] {
    var found: [String] = []
    let words = text.lowercased().split { !$0.isLetter }
    for w in words where britishSpellings[String(w)] != nil { found.append(String(w)) }
    return found
  }

  /// Capitalised phrases in `text` that look like UI names ("the Sound page", "turn up Listen") but
  /// are not among `known` titles (knob and page titles generated from the specs).
  /// Checks the word before " page", " knob" and " button".
  public static func unknownUINames(in text: String, known: Set<String>) -> [String] {
    var unknown: [String] = []
    let tokens = text.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
    for (i, t) in tokens.enumerated() where i > 0 && ["page", "knob", "button"].contains(t.lowercased()) {
      let name = tokens[i - 1]
      guard let first = name.first, first.isUppercase else { continue }
      if !known.contains(name) { unknown.append(name) }
    }
    return unknown
  }
}
