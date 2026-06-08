import SwiftUI
import PhotosUI
import SwiftData

struct ScanView: View {
    @State private var viewModel = ScannerViewModel()
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isCameraPresented = false
    @State private var isNormalPhotoPresented = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
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
                
                // 2. Photo Library Picker
                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("Select from Photos", systemImage: "photo.on.rectangle")
                        .font(.subheadline).foregroundColor(.blue).padding(.vertical, 10).frame(maxWidth: .infinity)
                        .background(Color.blue.opacity(0.1)).cornerRadius(10)
                }
            }
            .padding(.horizontal)
            .onChange(of: selectedPhotoItem) { _, newItem in
                Task.detached {
                    if let data = try? await newItem?.loadTransferable(type: Data.self), let uiImage = UIImage(data: data) {
                        await MainActor.run { viewModel.processImage(uiImage) }
                    }
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
                            ForEach(parsed.items) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(item.name)
                                            if let num = item.itemNumber { Text(num).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                        Text(String(format: "$%.2f", item.price))
                                            .foregroundColor(item.confidence < 0.8 ? .orange : .primary)
                                    }
                                    
                                    if let disc = item.discount {
                                        HStack {
                                            Text("  └ Discount").font(.caption).italic().foregroundStyle(.secondary)
                                            Spacer()
                                            Text(String(format: "-$%.2f", abs(disc))).font(.caption).italic().foregroundStyle(.secondary)
                                        }
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
                        }
                    }
                }
            }
        }
        .navigationTitle("New Scan")
        .sheet(isPresented: $isCameraPresented) {
            CameraScannerView(isPresented: $isCameraPresented) { capturedImage in
                viewModel.processImage(capturedImage)
            } didFinishWithError: { error in
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
    
    private func saveReceipt(_ parsed: ParsedReceipt) {
        let newReceipt = Receipt(storeName: parsed.storeName, receiptDate: parsed.date, total: parsed.total, tax: parsed.tax, rawText: viewModel.recognizedText)
        for item in parsed.items {
            newReceipt.items.append(ScannedItem(name: item.name, itemNumber: item.itemNumber, price: item.price))
        }
        modelContext.insert(newReceipt)
        dismiss()
    }
}
