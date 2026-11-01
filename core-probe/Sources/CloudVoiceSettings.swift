import UIKit
import Security

enum CloudVoiceKeys {
    static var asrHost: String { CloudASRHostSettings.current() }
    static var asrService: String { CloudASRHostSettings.service(for: asrHost) }
    static let llmService = "RayNeo.CloudLLM.https.api.deepseek.com.chat.completions"
    static let enabledKey = "cloudVoiceConsent.v1"
    static func get(_ service: String) -> String? {
        var item: CFTypeRef?
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service, kSecAttrAccount as String:"user-api-key",
            kSecReturnData as String:true, kSecMatchLimit as String:kSecMatchLimitOne]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data:data,encoding:.utf8)
    }
    static var ready: Bool { CloudASRHostSettings.normalize(asrHost) != nil && Self.get(asrService) != nil && Self.get(llmService) != nil }
    static func save(_ value: String, service: String) -> Bool {
        let key = value.trimmingCharacters(in:.whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.utf8.count <= 512,
              !key.contains(where: { $0.isWhitespace }) else { return false }
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:service, kSecAttrAccount as String:"user-api-key"]
        let attributes: [String:Any] = [kSecValueData as String:Data(key.utf8),
            kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary,nil) == errSecSuccess
        }
        return result == errSecSuccess
    }
}

final class CloudVoiceSettingsController: UIViewController {
    var changed: ((Bool) -> Void)?
    private let asr = UITextField(), llm = UITextField(), host = UITextField(), note = UILabel()
    private let llmBase = UITextField(), llmModel = UITextField()
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        let title = UILabel(); title.text = "Cloud Voice Test"; title.font = .preferredFont(forTextStyle:.title1)
        stack.addArrangedSubview(title)
        note.numberOfLines = 0
        note.text = "Alibaba Cloud ASR → DeepSeek V4 Flash\nThinking disabled · streamed output · cloud VAD\nAfter wake-up, audio goes to your configured Alibaba Cloud space and recognized text goes to DeepSeek. Both sides may bill. No TTS, no tool execution. Keys stay in this device's Keychain only; logs never record audio or content."
        stack.addArrangedSubview(note)
        host.placeholder = "Your Alibaba Cloud ASR host (no protocol/path)"
        host.text = CloudASRHostSettings.current(); host.borderStyle = .roundedRect
        host.autocapitalizationType = .none; host.autocorrectionType = .no
        stack.addArrangedSubview(host)
        llmBase.placeholder = "LLM base URL (OpenAI-compatible, e.g. https://api.deepseek.com)"
        llmBase.text = CloudLLMEndpointSettings.current.baseURL; llmBase.borderStyle = .roundedRect
        llmBase.autocapitalizationType = .none; llmBase.autocorrectionType = .no
        stack.addArrangedSubview(llmBase)
        llmModel.placeholder = "LLM model (e.g. deepseek-v4-flash)"
        llmModel.text = CloudLLMEndpointSettings.current.model; llmModel.borderStyle = .roundedRect
        llmModel.autocapitalizationType = .none; llmModel.autocorrectionType = .no
        stack.addArrangedSubview(llmModel)
        for (field, identifier, placeholder) in [(asr,"cloud-asr-key","Alibaba Cloud API Key"),(llm,"cloud-llm-key","DeepSeek API Key")] {
            field.isSecureTextEntry = true; field.accessibilityIdentifier = identifier
            field.placeholder = placeholder; field.borderStyle = .roundedRect
            field.autocapitalizationType = .none; field.autocorrectionType = .no
            field.textContentType = .password
            stack.addArrangedSubview(field)
        }
        for (title, action) in [("Save & Enable Cloud Conversation",#selector(save)),("Disable Cloud, Back to Random Test",#selector(disable)),("Back",#selector(back))] {
            let button = UIButton(type:.system); button.setTitle(title,for:.normal)
            button.heightAnchor.constraint(equalToConstant:44).isActive = true
            button.addTarget(self,action:action,for:.touchUpInside); stack.addArrangedSubview(button)
        }
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:24),
            stack.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-20)])
    }
    @objc private func save() {
        let a = asr.text ?? "", b = llm.text ?? ""
        guard let target = CloudASRHostSettings.normalize(host.text ?? "") else { note.text = "Enter a valid Alibaba Cloud ASR host name. Cloud upload is not enabled."; return }
        guard CloudLLMEndpointSettings.save(baseURL: llmBase.text, model: llmModel.text) else {
            note.text = "LLM endpoint/model could not be saved. Base URL must be http(s) with no credentials; model must be non-empty."; return
        }
        let service = CloudASRHostSettings.service(for: target)
        let okA = a.isEmpty ? CloudVoiceKeys.get(service) != nil : CloudVoiceKeys.save(a,service:service)
        let okB = b.isEmpty ? CloudVoiceKeys.get(CloudVoiceKeys.llmService) != nil : CloudVoiceKeys.save(b,service:CloudVoiceKeys.llmService)
        asr.text = ""; llm.text = ""
        guard okA && okB else { note.text = "Keys were not saved completely — check your input. Cloud upload is not enabled."; return }
        CloudASRHostSettings.save(target)
        UserDefaults.standard.set(true,forKey:CloudVoiceKeys.enabledKey)
        changed?(true); dismiss(animated:true)
    }
    @objc private func disable() {
        UserDefaults.standard.set(false,forKey:CloudVoiceKeys.enabledKey)
        changed?(false); dismiss(animated:true)
    }
    @objc private func back() { dismiss(animated:true) }
}
