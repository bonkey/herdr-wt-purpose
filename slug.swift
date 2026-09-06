// slug.swift — default slug backend: Apple's on-device Foundation Model.
// Reads the whole prompt (instructions + purpose) on stdin, prints the model's reply.
// Exit 2 when Apple Intelligence is unavailable so scaffold.sh can fall back.
// Run through the `swift` interpreter: `printf '…' | swift slug.swift`.
import Foundation
import FoundationModels

let model = SystemLanguageModel.default
guard case .available = model.availability else {
    FileHandle.standardError.write("slug.swift: model unavailable: \(model.availability)\n".data(using: .utf8)!)
    exit(2)
}
let prompt = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
let reply = try await LanguageModelSession().respond(to: prompt, options: GenerationOptions(temperature: 0))
print(reply.content)
