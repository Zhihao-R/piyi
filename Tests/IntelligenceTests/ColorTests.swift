import Testing
@testable import Intelligence

@Suite struct ColorTests {
    @Test func mainColorPrefersHueOverBackground() {
        // A red patch covering 20% on a white background: counts as red
        #expect(ColorProfile(share: [.white: 0.7, .red: 0.2, .gray: 0.1], swatches: []).main == .red)
        // Too little color: counts as the white that covers the most
        #expect(ColorProfile(share: [.white: 0.8, .blue: 0.1, .gray: 0.1], swatches: []).main == .white)
        #expect(ColorProfile(share: [:], swatches: []).main == nil)
    }

    @Test func readsStoredJSON() {
        let json = ##"{"share":{"green":0.6,"black":0.4},"swatches":["#336633"]}"##
        #expect(ColorProfile(json: json)?.main == .green)
        #expect(ColorProfile(json: "坏的") == nil)
    }
}
