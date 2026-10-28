import Foundation

/// Taille du personnage, calculée comme dans l'original (PetMetrics.init et AppDelegate).
enum PetSizing {
    /// Niveaux du menu « Size » de l'original et leur valeur.
    static let levels: [(name: String, value: Double)] = [
        ("Tiny", 0.5), ("Small", 0.75), ("Normal", 1.0), ("Large", 1.5), ("Huge", 2.0),
    ]

    static func label(for size: Double) -> String {
        levels.first { $0.value == size }?.name ?? String(format: "%g", size)
    }

    /// Facteur lié à l'écran : largeur (points) ÷ 900, entre 1,2 et 3,2.
    static func displayFactor(screenWidth: CGFloat) -> Double {
        min(max(Double(screenWidth) / 900, 1.2), 3.2)
    }

    /// Taille appliquée : taille choisie × facteur d'écran, tronquée au 0,05.
    static func applied(size: Double, screenWidth: CGFloat) -> Double {
        (size * displayFactor(screenWidth: screenWidth) * 20).rounded(.towardZero) / 20
    }

    /// Côté (points) du cadre carré d'un personnage. Debout, il fait `appliquée × 160` points de haut ;
    /// `standHeight` (0,76 par défaut) est sa hauteur en fraction du cadre.
    /// `maxCanvas` : plafond de sécurité (plus grand cadre qui tient dans la zone visible), absent de l'original.
    static func canvasPoints(size: Double, screenWidth: CGFloat, standHeight: CGFloat, maxCanvas: CGFloat? = nil) -> CGFloat {
        var points = (applied(size: size, screenWidth: screenWidth) * 160 / Double(standHeight)).rounded(.down)
        if let maxCanvas { points = min(points, Double(maxCanvas).rounded(.down)) }
        return CGFloat(max(points, 64))
    }
}
