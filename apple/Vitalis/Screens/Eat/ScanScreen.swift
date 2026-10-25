import SwiftUI
import VitalisKit
import VitalisUI

/// Frames 16 and 17: scan a barcode, look it up on the server, add it or fall back to the label, Describe, or typed numbers.
struct ScanScreen: View {
    let store: EatStore
    let slot: String
    let onDescribe: (String) -> Void
    let onDone: () -> Void
    @State private var barcode: BarcodeStore
    @State private var form: ManualFood?
    @State private var photographing = false
    @State private var photo: LabelImage?
    @State private var reading = false
    @State private var typedCode = ""
    /// Share of the pack (or serving) eaten, set before adding: half a bag of chips is ½.
    @State private var amount: Double = 1

    init(store: EatStore, slot: String, barcode: BarcodeStore = .live(), onDescribe: @escaping (String) -> Void, onDone: @escaping () -> Void) {
        self.store = store; self.slot = slot; self.onDescribe = onDescribe; self.onDone = onDone
        _barcode = State(initialValue: barcode)
    }

    var body: some View {
        EatChrome(status: "Scanning", pulse: store.todayPulse) {
            VStack(spacing: 0) {
                topBar
                ZStack(alignment: .bottom) {
                    camera
                    panel
                }
            }
        }
        .background(VColor.ground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(item: $form) { f in
            ManualFoodForm(food: f, slot: slot) { item, draft in
                form = nil
                Task {
                    await store.rememberBarcode(f.code, item: item)
                    await store.log([draft], slot: slot, source: "barcode", sourceRef: f.code)
                }
                onDone()
            }
        }
        // The form sheet can only open once the picker sheet is gone, so reading starts on dismiss.
        .sheet(isPresented: $photographing, onDismiss: readPhoto) {
            LabelPhotoPicker { image in photo = image; photographing = false }.ignoresSafeArea()
        }
    }

    private func readPhoto() {
        guard let image = photo else { return }
        photo = nil
        reading = true
        Task {
            let values = LabelParser.parse(await LabelReader.rows(from: image).joined(separator: "\n"))
            reading = false
            form = ManualFood(code: code ?? "", values: values, fromPhoto: true)
        }
    }

    private var code: String? {
        switch barcode.phase {
        case .scanning: nil
        case .looking(let c), .notFound(let c), .failed(let c, _): c
        case .found(let r): r.code
        }
    }

    private var topBar: some View {
        ZStack {
            MonoLabel("Adding to \(slot.slotTitle)", tint: .bone)
            HStack {
                Button(action: onDone) {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(VColor.bone)
                        .frame(width: 40, height: 40)
                        .overlay(RoundedRectangle(cornerRadius: VRadius.button, style: .continuous).inset(by: 0.75).stroke(VColor.future, lineWidth: 1.5))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                Spacer()
            }
        }
        .padding(.horizontal, VSpace.gutter)
        .padding(.top, 10).padding(.bottom, 16)
    }

    // MARK: Camera

    private var camera: some View {
        ZStack(alignment: .top) {
            VColor.camera
            if case .scanning = barcode.phase, BarcodeScannerView.isAvailable {
                BarcodeScannerView { raw in Task { await barcode.scanned(raw) } }
            }
            VStack(spacing: 18) {
                viewfinder
                if let line = codeLine { MonoLabel(line.text, tint: line.tint) }
            }
            .padding(.top, 64)
        }
    }

    private var notFound: Bool { if case .notFound = barcode.phase { true } else { false } }

    @ViewBuilder private var viewfinder: some View {
        if notFound {
            Rectangle().stroke(VColor.watch, lineWidth: 2).frame(width: 240, height: 150)
        } else {
            Brackets().stroke(VColor.bone, style: StrokeStyle(lineWidth: 3)).frame(width: 280, height: 180)
        }
    }

    private var codeLine: (text: String, tint: VTint)? {
        switch barcode.phase {
        case .scanning: BarcodeScannerView.isAvailable ? ("Point at the barcode", .steel) : nil
        case .looking(let c): ("Looking up · \(BarcodeStore.grouped(c))", .steel)
        case .found(let r): ("Found · \(BarcodeStore.grouped(r.code))", .bone)
        case .notFound: nil
        case .failed(let c, _): (BarcodeStore.grouped(c), .steel)
        }
    }

    // MARK: Panels

    @ViewBuilder private var panel: some View {
        switch barcode.phase {
        case .found(let r): if let item = r.item { foundPanel(r, item) }
        case .notFound(let c): notFoundPanel(c)
        case .failed(_, let line): sheetPanel {
            MonoLabel(line, tint: .watch)
            SecondaryButton("Scan again", size: .full) { barcode.rescan() }.padding(.top, 16)
        }
        case .scanning: if !BarcodeScannerView.isAvailable { typeCodePanel }
        case .looking: EmptyView()
        }
    }

    private func sheetPanel<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, VSpace.gutter).padding(.top, 24).padding(.bottom, 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VColor.sheet, in: UnevenRoundedRectangle(topLeadingRadius: VRadius.sheet, topTrailingRadius: VRadius.sheet, style: .continuous))
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: VRadius.sheet, topTrailingRadius: VRadius.sheet, style: .continuous)
                    .stroke(VColor.rule, lineWidth: 1).frame(height: VRadius.sheet * 2, alignment: .top)
            }
            .ignoresSafeArea(.container, edges: .bottom)
    }

    private func foundPanel(_ r: BarcodeResponse, _ item: BarcodeResponse.Item) -> some View {
        let portion = ScanPortion(item: item, factor: amount)
        return sheetPanel {
            VStack(alignment: .leading, spacing: 8) {
                if let label = r.label { MonoLabel(label) }
                HeadlineLines(HeadlineLines.split(item.name, maxChars: 18), size: 28)
            }
            AmountControl(factor: $amount, baseGrams: portion.baseGrams, baseName: portion.baseName, kcal: portion.nutrients.kcal,
                          maxFactor: portion.isPack ? 1 : 3)
                .padding(.top, 16)
            MacroColumns(protein: portion.nutrients.proteinG, carbs: portion.nutrients.carbsG, fat: portion.nutrients.fatG).padding(.top, 14)
            PrimaryButton("Add to \(slot.slotTitle) · \(FoodFormat.kcal(portion.nutrients.kcal)) kcal") {
                let n = portion.nutrients
                let draft = FoodDraft(name: item.name, portionText: portion.label, grams: portion.grams, kcal: n.kcal,
                                      proteinG: n.proteinG, carbsG: n.carbsG, fatG: n.fatG)
                Task { await store.log([draft], slot: slot, source: "barcode", sourceRef: r.code) }
                onDone()
            }
            .padding(.top, 18)
        }
    }

    private func notFoundPanel(_ c: String) -> some View {
        sheetPanel {
            MonoLabel("Not found · \(BarcodeStore.grouped(c))", tint: .watch)
            HeadlineLines(HeadlineLines.split("Not in Open Food Facts yet", maxChars: 16), size: 30).padding(.top, 10)
            Text("Common for Indian brands. Pick another way and we'll remember this barcode.").vReading(13, tint: .steel)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 12).padding(.bottom, 14)
            if reading { MonoLabel("Reading the label").padding(.bottom, 10) }
            option("camera", "Photograph the label", "Reads calories and macros") { photographing = true }
            if store.describeAvailable { option("pencil", "Describe it", "\"Mango lassi, 250 ml bottle\"") { onDescribe(c) } }
            option("keyboard", "Type the numbers", "Per serving") { form = ManualFood(code: c, values: .init(), fromPhoto: false) }
        }
    }

    private func option(_ icon: String, _ title: String, _ detail: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Rule()
            Button(action: action) {
                HStack(spacing: 16) {
                    Image(systemName: icon).font(.title3).foregroundStyle(VColor.bone).frame(width: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).vHeadline(22)
                        MonoLabel(detail, size: .small)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.body.weight(.semibold)).foregroundStyle(VColor.steel)
                }
                .frame(minHeight: 62).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Simulator and devices without VisionKit scanning: type the digits instead.
    private var typeCodePanel: some View {
        sheetPanel {
            MonoLabel("Camera scanning isn't available here")
            HStack(spacing: 12) {
                TextField("", text: $typedCode, prompt: Text("Barcode digits").foregroundStyle(VColor.steel))
                    .vReading(14).keyboardType(.numberPad).tint(VColor.bone)
                    .padding(.horizontal, 16).frame(height: 48)
                    .overlay(RoundedRectangle(cornerRadius: VRadius.button, style: .continuous).inset(by: 0.75).stroke(VColor.future, lineWidth: 1.5))
                SecondaryButton("Look up", enabled: (8...14).contains(typedCode.filter(\.isNumber).count)) {
                    Task { await barcode.scanned(typedCode) }
                }
            }
            .padding(.top, 14)
        }
    }
}

/// Four 30 pt corner brackets of the viewfinder.
private struct Brackets: Shape {
    func path(in r: CGRect) -> Path {
        let l: CGFloat = 30
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.minX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.maxY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - l))
        return p
    }
}

#if DEBUG
#Preview("Scan · found") {
    let b = BarcodeStore { _ in EatPreview.decode(BarcodeResponse.self, "barcode")! }
    return ScanScreen(store: EatPreview.store(), slot: "snack", barcode: b, onDescribe: { _ in }, onDone: {})
        .task { await b.scanned("8901063010031") }.onAppear { VFont.register() }
}

#Preview("Scan · not found") {
    let b = BarcodeStore { _ in EatPreview.decode(BarcodeResponse.self, "barcode-not-found")! }
    return ScanScreen(store: EatPreview.store(), slot: "snack", barcode: b, onDescribe: { _ in }, onDone: {})
        .task { await b.scanned("8904109450018") }.onAppear { VFont.register() }
}

#Preview("Scan · type the code") {
    ScanScreen(store: EatPreview.store(), slot: "snack", barcode: BarcodeStore { _ in throw APIError.notFound }, onDescribe: { _ in }, onDone: {})
        .onAppear { VFont.register() }
}
#endif

/// What a scanned product's amount means: a share of the whole pack when its size is known, else of one serving.
/// Nutrients come from per-100 g values when the server has them, so ½ of a 52 g pack is exactly 26 g.
struct ScanPortion {
    let baseGrams: Double?
    let baseName: String
    let isPack: Bool
    let grams: Double?
    let label: String
    let nutrients: Nutrients

    init(item: BarcodeResponse.Item, factor: Double) {
        if let pack = item.packageG, pack > 0 { baseGrams = pack; baseName = "pack"; isPack = true }
        else { baseGrams = item.serving.grams; baseName = "serving"; isPack = false }
        let g = baseGrams.map { $0 * factor }
        grams = g.map { ($0 * 10).rounded() / 10 }
        let share = AmountControl.factorText(factor)
        label = isPack ? (factor == 1 ? "1 pack" : "\(share) pack") + (g.map { " · \(AmountControl.grams($0)) g" } ?? "")
            : factor == 1 ? item.serving.label.lowercased() : "\(share) × \(item.serving.label.lowercased())"
        if let per = item.per100g, let g {
            let f = g / 100
            nutrients = Nutrients(kcal: (per.kcal * f).rounded(), proteinG: per.proteinG.map { ($0 * f * 10).rounded() / 10 },
                                  carbsG: per.carbsG.map { ($0 * f * 10).rounded() / 10 }, fatG: per.fatG.map { ($0 * f * 10).rounded() / 10 })
        } else {
            let s = item.serving
            nutrients = Nutrients(kcal: (s.kcal * factor).rounded(), proteinG: s.proteinG.map { $0 * factor },
                                  carbsG: s.carbsG.map { $0 * factor }, fatG: s.fatG.map { $0 * factor })
        }
    }
}
