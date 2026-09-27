import Foundation

public enum Units {
    public static let millimetersPerInch = 25.4

    public static func millimeters(fromInches inches: Double) -> Double {
        inches * millimetersPerInch
    }

    public static func inches(fromMillimeters millimeters: Double) -> Double {
        millimeters / millimetersPerInch
    }

    /// Exactly three digits after the decimal point.
    public static func formatMillimeters(_ millimeters: Double) -> String {
        String(format: "%.3f", millimeters)
    }

    /// Signed, exactly three digits after the decimal point. Example: `+0.004`, `-0.012`.
    public static func formatSignedMillimeters(_ millimeters: Double) -> String {
        String(format: "%+.3f", millimeters)
    }

    /// Exactly three digits after the decimal point.
    public static func formatInches(_ inches: Double) -> String {
        String(format: "%.3f", inches)
    }

    /// Signed, exactly three digits after the decimal point.
    public static func formatSignedInches(_ inches: Double) -> String {
        String(format: "%+.3f", inches)
    }
}
