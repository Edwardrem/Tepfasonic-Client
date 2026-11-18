import Testing
@testable import TepfaAgent

@Suite("Caimex model choices")
struct CaimexModelChoicesTests {
    @Test func keepsTheCatalogueOrder() {
        let models = [
            CaimexModel(id: "alpha", featured: true),
            CaimexModel(id: "beta"),
            CaimexModel(id: "caimex/auto"),
        ]

        let choices = CaimexModelChoices(models: models, current: "beta")

        #expect(choices.ids == ["alpha", "beta", "caimex/auto"])
    }

    @Test func keepsASavedModelTheListNoLongerHas() {
        let choices = CaimexModelChoices(models: [CaimexModel(id: "alpha")], current: "old-model")

        #expect(choices.ids == ["old-model", "alpha"], "the user's model stays selectable")
    }

    @Test func doesNotDuplicateASavedModelTheListHas() {
        let models = [CaimexModel(id: "alpha"), CaimexModel(id: "beta")]

        let choices = CaimexModelChoices(models: models, current: "alpha")

        #expect(choices.ids == ["alpha", "beta"])
    }

    @Test func anEmptySavedModelAddsNothing() {
        let choices = CaimexModelChoices(models: [CaimexModel(id: "alpha")], current: "")

        #expect(choices.ids == ["alpha"])
    }

    @Test func anEmptyListStillOffersTheSavedModel() {
        let choices = CaimexModelChoices(models: [], current: "deepseek-v4-flash")

        #expect(choices.ids == ["deepseek-v4-flash"])
    }

    @Test func keepsOpaqueIdsWhole() {
        let models = [CaimexModel(id: "ollama/qwen3-vl:8b")]

        let choices = CaimexModelChoices(models: models, current: "ollama/qwen3-vl:8b")
        let missing = CaimexModelChoices(models: [], current: "caimex/auto")

        #expect(choices.ids == ["ollama/qwen3-vl:8b"])
        #expect(missing.ids == ["caimex/auto"])
    }
}
