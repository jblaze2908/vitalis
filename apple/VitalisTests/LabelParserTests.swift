import Testing
@testable import Vitalis

@Suite struct LabelParserTests {
    @Test func indianSingleServingColumn() {
        let v = LabelParser.parse("""
        NUTRITIONAL INFORMATION
        Per serving (40 g)
        Energy 190 kcal
        Protein 10 g
        Carbohydrate 20g
        of which Sugars 8 g
        Total Fat 7 g
        Saturated Fat 3 g
        Trans Fat 0 g
        """)
        #expect(v == LabelParser.Values(kcal: 190, proteinG: 10, carbsG: 20, fatG: 7))
    }

    @Test func indianPer100ThenPerServePrefersServing() {
        let v = LabelParser.parse("""
        Nutritional Information Per 100 g Per serve (30 g)
        Energy (kcal) 452 136
        Protein (g) 8.5 2.6
        Carbohydrate (g) 62.0 18.6
        Total Sugars (g) 20 6
        Total Fat (g) 19.0 5.7
        Saturated Fat (g) 9.1 2.7
        """)
        #expect(v == LabelParser.Values(kcal: 136, proteinG: 2.6, carbsG: 18.6, fatG: 5.7))
    }

    @Test func euKilojoulesAndDecimalCommas() {
        let v = LabelParser.parse("""
        Nutrition declaration Per 100 g Per portion (30 g)
        Energy 1046 kJ / 250 kcal 314 kJ / 75 kcal
        Fat 4,5 g 1,4 g
        of which saturates 0,8 g 0,2 g
        Carbohydrate 42 g 12,6 g
        Protein 9,8 g 2,9 g
        """)
        #expect(v == LabelParser.Values(kcal: 75, proteinG: 2.9, carbsG: 12.6, fatG: 1.4))
    }

    @Test func usNutritionFactsIgnoresDailyValuePercents() {
        let v = LabelParser.parse("""
        Nutrition Facts
        8 servings per container
        Serving size 2/3 cup (55g)
        Amount per serving
        Calories 230
        Total Fat 8g 10%
        Saturated Fat 1g 5%
        Trans Fat 0g
        Cholesterol 0mg 0%
        Sodium 160mg 7%
        Total Carbohydrate 37g 13%
        Dietary Fiber 4g 14%
        Total Sugars 12g
        Protein 3g
        """)
        #expect(v == LabelParser.Values(kcal: 230, proteinG: 3, carbsG: 37, fatG: 8))
    }

    @Test func servingColumnFirstInHeader() {
        let v = LabelParser.parse("""
        Per serving (25 g) Per 100 g
        Energy 100 kcal 400 kcal
        Protein 5 g 20 g
        """)
        #expect(v.kcal == 100 && v.proteinG == 5)
    }

    @Test func noHeaderTwoColumnsTakesTheSecond() {
        let v = LabelParser.parse("Energy 520 kcal 156 kcal\nProtein 20 g 6 g")
        #expect(v.kcal == 156 && v.proteinG == 6)
    }

    @Test func valueOnTheNextRowAndKilojouleRowsSkipped() {
        let v = LabelParser.parse("""
        Energy (kJ) 1890
        Energy (kcal) 452
        Protein
        12.5 g
        """)
        #expect(v.kcal == 452 && v.proteinG == 12.5)
    }

    @Test func slashPairedKilojoulesWithoutUnits() {
        let v = LabelParser.parse("Energy kJ/kcal 1046/250")
        #expect(v.kcal == 250)
    }

    @Test func thousandsSeparatorAndNothingFound() {
        #expect(LabelParser.parse("Energy 1,046 kJ 250 kcal").kcal == 250)
        #expect(LabelParser.parse("Ingredients: milk, sugar").isEmpty)
    }
}
