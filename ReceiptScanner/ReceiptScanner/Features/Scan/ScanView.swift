import SwiftUI
import UniformTypeIdentifiers
import SwiftData

struct ScanView: View {
    @State private var viewModel = ScannerViewModel()
    @State private var isFileImporterPresented = false
    @State private var isCameraPresented = false
    @State private var dragIndex: Int?
    @State private var dragOffset: CGFloat = 0
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        VStack(spacing: 20) {
            if let img = viewModel.selectedImage {
                Image(uiImage: img).resizable().scaledToFit().frame(height: 200).cornerRadius(12).padding()
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.viewfinder").font(.system(size: 60)).foregroundStyle(.secondary)
                    Text("Ready to Scan").font(.headline)
                }.padding(.vertical, 40)
            }
            
            VStack(spacing: 12) {
                // 1. Documentation Camera Button
                Button {
                    isCameraPresented = true
                } label: {
                    Label("Scan Document", systemImage: "doc.viewfinder")
                        .font(.headline).foregroundColor(.white).padding().frame(maxWidth: .infinity)
                        .background(Color.blue).cornerRadius(12)
                }
                
                // 2. PDF File Importer
                Button {
                    isFileImporterPresented = true
                } label: {
                    Label("Select PDF from Files", systemImage: "doc.badge.plus")
                        .font(.subheadline).foregroundColor(.blue).padding(.vertical, 10).frame(maxWidth: .infinity)
                        .background(Color.blue.opacity(0.1)).cornerRadius(10)
                }
            }
            .padding(.horizontal)
            // Prevent overlapping scans: the view model also guards, but
            // disabling the inputs makes the state visible to the user.
            .disabled(viewModel.isScanning)
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.pdf],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        if let data = try? Data(contentsOf: url) {
                            viewModel.processPDF(data: data)
                        }
                    }
                case .failure(let error):
                    viewModel.errorMessage = error.localizedDescription
                }
            }
            
            if viewModel.isScanning {
                ProgressView("Analyzing...").padding()
            } else if let parsed = viewModel.parsedReceipt {
                List {
                    Section("Review") {
                        LabeledContent("Store", value: parsed.storeName ?? "Unknown")
                        if let date = parsed.date { LabeledContent("Date", value: date.formatted(date: .abbreviated, time: .omitted)) }
                        if let sub = parsed.subtotal { LabeledContent("Subtotal", value: String(format: "$%.2f", sub)) }
                        if let total = parsed.total { LabeledContent("Total", value: String(format: "$%.2f", total)).font(.headline) }
                        
                        if let warning = parsed.validationWarning {
                            Text(warning).font(.caption).foregroundColor(.red).listRowBackground(Color.red.opacity(0.1))
                        }

                        if parsed.wasAIRepaired {
                            Label("Some prices were moved to the correct items automatically. Please double-check them.", systemImage: "wand.and.stars")
                                .font(.caption).foregroundStyle(.orange)
                        }

                        if viewModel.isRepairing {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text("Checking mismatch against raw text…").font(.caption).foregroundStyle(.secondary)
                            }
                        }

                        Button { saveReceipt(parsed) } label: {
                            Label("Save to History", systemImage: "checkmark.circle.fill").font(.headline).frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent).listRowBackground(Color.clear)
                    }
                    
                    Section("Raw Recognized Text") {
                        Text(viewModel.recognizedText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    }
                    
                    if !parsed.items.isEmpty {
                        Section("Items") {
                            Text("If a price landed on the wrong item, drag it up or down to shift it onto the right row.")
                                .font(.caption).foregroundStyle(.secondary)

                            ForEach(Array(parsed.items.enumerated()), id: \.element.id) { index, item in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(item.name)
                                            if let num = item.itemNumber { Text(num).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                        Text(String(format: "$%.2f", item.price))
                                            .foregroundColor(item.confidence < 0.8 ? .orange : .primary)
                                            .padding(.vertical, 4).padding(.horizontal, 8)
                                            .background(dragIndex == index ? Color.accentColor.opacity(0.15) : Color.clear)
                                            .cornerRadius(6)
                                            .offset(y: dragIndex == index ? dragOffset : 0)
                                            .gesture(
                                                DragGesture()
                                                    .onChanged { value in
                                                        dragIndex = index
                                                        dragOffset = value.translation.height
                                                    }
                                                    .onEnded { value in
                                                        let threshold: CGFloat = 24
                                                        withAnimation(.spring(response: 0.3)) {
                                                            if value.translation.height > threshold {
                                                                viewModel.shiftPrice(at: index, down: true)
                                                            } else if value.translation.height < -threshold {
                                                                viewModel.shiftPrice(at: index, down: false)
                                                            }
                                                            dragIndex = nil
                                                            dragOffset = 0
                                                        }
                                                    }
                                            )
                                    }

                                    if let disc = item.discount {
                                        HStack {
                                            Text("  └ Discount").font(.caption).italic().foregroundStyle(.secondary)
                                            Spacer()
                                            Text(String(format: "-$%.2f", abs(disc))).font(.caption).italic().foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        viewModel.removeItem(id: item.id)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                            
                            if let diff = parsed.difference, abs(diff) > 0.01 {
                                HStack {
                                    Label("Correction Needed", systemImage: "plus.forwardslash.minus")
                                        .font(.subheadline).bold().foregroundColor(.red)
                                    Spacer()
                                    Text(String(format: "$%.2f", diff))
                                        .font(.subheadline).bold().foregroundColor(.red)
                                }
                                .padding(.vertical, 4)
                                .listRowBackground(Color.red.opacity(0.05))
                            }
                            
                            // Summary Section under items
                            if parsed.subtotal != nil || parsed.tax != nil || parsed.total != nil {
                                Divider()
                                
                                if let sub = parsed.subtotal {
                                    HStack {
                                        Text("Subtotal").foregroundStyle(.secondary)
                                        Spacer()
                                        Text(String(format: "$%.2f", sub)).foregroundStyle(.secondary)
                                    }
                                }
                                
                                if let tax = parsed.tax {
                                    HStack {
                                        Text("Tax").foregroundStyle(.secondary)
                                        Spacer()
                                        Text(String(format: "$%.2f", tax)).foregroundStyle(.secondary)
                                    }
                                }
                                
                                if let total = parsed.total {
                                    HStack {
                                        Text("Total").bold()
                                        Spacer()
                                        Text(String(format: "$%.2f", total)).bold()
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("New Scan")
        .alert("Scan Failed", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .alert("Receipt Still Doesn't Match", isPresented: $viewModel.mismatchUnresolved) {
            Button("Save Anyway") {
                if let parsed = viewModel.parsedReceipt { saveReceipt(parsed) }
            }
            Button("Retake Photo") {
                viewModel.reset()
                isCameraPresented = true
            }
        } message: {
            Text("The on-device model couldn't reconcile the items with the printed subtotal. Save it as-is, or retake the picture for a cleaner scan.")
        }
        .sheet(isPresented: $isCameraPresented) {
            CameraScannerView(isPresented: $isCameraPresented) { capturedImage in
                viewModel.processImage(capturedImage)
            } didFinishWithError: { error in
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
    
    private func saveReceipt(_ parsed: ParsedReceipt) {
        let newReceipt = Receipt(storeName: parsed.storeName, receiptDate: parsed.date, subtotal: parsed.subtotal, total: parsed.total, tax: parsed.tax, rawText: viewModel.recognizedText)
        // Insert before wiring the relationship so items are registered with
        // the same context, and record line order — SwiftData does not
        // preserve relationship array order.
        modelContext.insert(newReceipt)
        for (index, item) in parsed.items.enumerated() {
            newReceipt.items.append(ScannedItem(name: item.name, itemNumber: item.itemNumber, price: item.price, discount: item.discount, sortOrder: index))
        }
        do {
            try modelContext.save()
            viewModel.reset()
        } catch {
            viewModel.errorMessage = "Could not save receipt: \(error.localizedDescription)"
        }
    }
}
