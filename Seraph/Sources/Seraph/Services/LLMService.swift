import Foundation
@preconcurrency import Combine

/// Errors that can occur during LLM operations
public enum LLMError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case rateLimitExceeded
    case invalidAPIKey
    case requestFailed(Error)
    case decodingError(Error)
    case noDataReceived
    case invalidModel
    case invalidRequest
    case modelNotAvailable
    case contextTooLarge
    case generationFailed
    case unsupportedModel
    case invalidAPIKeyFormat
    case networkUnavailable
    case timeout
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The provided URL is invalid."
        case .invalidResponse:
            return "Received an invalid response from the server."
        case .rateLimitExceeded:
            return "Rate limit exceeded. Please try again later."
        case .invalidAPIKey, .invalidAPIKeyFormat:
            return "The provided API key is invalid or missing."
        case .requestFailed(let error):
            return "Request failed with error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .noDataReceived:
            return "No data was received from the server."
        case .invalidModel:
            return "The specified model is not available."
        case .invalidRequest:
            return "The request was invalid or malformed."
        case .modelNotAvailable:
            return "The requested model is not available."
        case .contextTooLarge:
            return "The conversation history is too long. Please start a new conversation."
        case .generationFailed:
            return "Failed to generate a response. Please try again."
        case .unsupportedModel:
            return "The selected model is not supported in this version of the app."
        case .networkUnavailable:
            return "Network is unavailable. Please check your connection and try again."
        case .timeout:
            return "The request timed out. Please try again."
        }
    }
    
    public var recoverySuggestion: String? {
        switch self {
        case .networkUnavailable:
            return "Please check your internet connection and try again."
        case .invalidAPIKey, .invalidAPIKeyFormat:
            return "Please check your API key in Settings and try again."
        case .contextTooLarge:
            return "Try starting a new conversation or summarizing the previous context."
        case .rateLimitExceeded:
            return "Please wait a few moments before trying again."
        default:
            return "Please try again later or contact support if the issue persists."
        }
    }
}

/// A type that can be used to handle completion of LLM operations
typealias CompletionHandler = (Result<String, Error>) -> Void

/// Protocol defining the interface for LLM services
@MainActor
public protocol LLMServiceProtocol: AnyObject {
    /// The base URL for the LLM API
    var baseURL: URL? { get set }
    
    /// The API key for the LLM service
    var apiKey: String? { get set }
    
    /// The default model ID to use
    var defaultModelId: String { get set }
    
    /// The maximum number of tokens to generate
    var maxTokens: Int { get set }
    
    /// The temperature for sampling (0.0 to 1.0)
    var temperature: Double { get set }
    
    /// The top-p value for nucleus sampling (0.0 to 1.0)
    var topP: Double { get set }
    
    /// The presence penalty (-2.0 to 2.0)
    var presencePenalty: Double { get set }
    
    /// The frequency penalty (-2.0 to 2.0)
    var frequencyPenalty: Double { get set }
    
    /// Generate a response for the given message
    /// - Parameters:
    ///   - message: The user's message
    ///   - model: The AI model to use
    ///   - systemPrompt: The system prompt to use
    ///   - history: The conversation history
    /// - Returns: A publisher that emits the response or an error
    func generateResponse(
        message: String,
        model: AIModel,
        systemPrompt: String,
        history: [Message]
    ) -> AnyPublisher<String, Error>
    
    /// Check if a model is available
    /// - Parameter model: The model to check
    /// - Returns: A boolean indicating if the model is available
    func isModelAvailable(_ model: AIModel) -> Bool
    
    /// Get the list of available models
    /// - Returns: An array of available models
    func availableModels() -> [AIModel]
    
    /// Cancel any ongoing requests
    func cancelAllRequests()
    
    /// Validate the API key
    /// - Parameter apiKey: The API key to validate
    /// - Returns: A boolean indicating if the API key is valid
    func validateAPIKey(_ apiKey: String) -> Bool
    
    /// Stream a response for a message
    /// - Parameters:
    ///   - message: The message to send to the LLM
    ///   - model: The model to use for the completion
    ///   - systemPrompt: The system prompt to set the behavior of the assistant
    ///   - temperature: Controls randomness (0.0 to 1.0)
    /// - Returns: A publisher that emits response chunks or an error
    func streamMessage(
        _ message: String,
        model: AIModel,
        systemPrompt: String,
        temperature: Double
    ) -> AnyPublisher<String, Error>
    
    /// Generate a response for a conversation (legacy method)
    /// - Parameters:
    ///   - prompt: The user's input prompt
    ///   - model: The model to use for the completion
    ///   - conversationHistory: The history of messages in the conversation
    ///   - completion: Completion handler with the result
    func generateResponse(
        prompt: String,
        model: String,
        conversationHistory: [Message],
        completion: @escaping (Result<String, Error>) -> Void
    )
    
    /// Send a message to the LLM and get a response
    /// - Parameters:
    ///   - message: The message to send
    ///   - conversation: The conversation to add the message to
    ///   - systemPrompt: The system prompt to use
    ///   - model: The AI model to use
    /// - Returns: The generated response as a string
    func sendMessage(
        _ message: String,
        conversation: Conversation,
        systemPrompt: String,
        model: AIModel
    ) async throws -> String
}

/// A service that handles communication with language models
@MainActor
public final class LLMService: LLMServiceProtocol {
    // MARK: - Properties
    
    /// Shared instance of the LLMService
    public static let shared = LLMService()
    
    /// The URL session to use for network requests
    private let session: URLSession
    
    /// Headers to include in API requests
    private var requestHeaders: [String: String] = [:]
    
    // Private initializer to enforce singleton pattern
    private init() {
        self.session = URLSession.shared
        
        // Configure default headers if needed
        var headers = self.requestHeaders
        headers["Content-Type"] = "application/json"
        self.requestHeaders = headers
    }
    
    /// The active tasks
    private var tasks: [URLSessionTask] = []
    
    /// The base URL for the LLM API
    public var baseURL: URL? {
        get {
            guard let urlString = UserDefaults.standard.string(forKey: "llmBaseURL") else {
                return nil
            }
            return URL(string: urlString)
        }
        set {
            UserDefaults.standard.set(newValue?.absoluteString, forKey: "llmBaseURL")
        }
    }
    
    /// The API key for the LLM service
    public var apiKey: String? {
        get { UserDefaults.standard.string(forKey: "llmAPIKey") }
        set { UserDefaults.standard.set(newValue, forKey: "llmAPIKey") }
    }
    
    /// The default model ID to use
    public var defaultModelId: String {
        get {
            if let modelId = UserDefaults.standard.string(forKey: "defaultModelId") {
                return modelId
            }
            return AIModel.defaultModel.id
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "defaultModelId")
        }
    }
    
    /// The default model to use
    public var defaultModel: AIModel {
        AIModel.allModels.first { $0.id == defaultModelId } ?? AIModel.defaultModel
    }
    
    /// The maximum number of tokens to generate
    public var maxTokens: Int = 2048 {
        didSet {
            UserDefaults.standard.set(maxTokens, forKey: "maxTokens")
        }
    }
    
    /// The temperature for sampling (0.0 to 1.0)
    public var temperature: Double = 0.7 {
        didSet {
            UserDefaults.standard.set(temperature, forKey: "temperature")
        }
    }
    
    /// The top-p value for nucleus sampling (0.0 to 1.0)
    public var topP: Double = 0.9 {
        didSet {
            UserDefaults.standard.set(topP, forKey: "topP")
        }
    }
    
    /// The presence penalty (-2.0 to 2.0)
    public var presencePenalty: Double = 0.0 {
        didSet {
            UserDefaults.standard.set(presencePenalty, forKey: "presencePenalty")
        }
    }
    
    /// The frequency penalty (-2.0 to 2.0)
    public var frequencyPenalty: Double = 0.0 {
        didSet {
            UserDefaults.standard.set(frequencyPenalty, forKey: "frequencyPenalty")
        }
    }
    
    /// The JSON decoder to use
    private let decoder = JSONDecoder()
    
    /// The queue for processing responses
    private let responseQueue = DispatchQueue(label: "com.seraph.llmservice.response")
    
    /// The cancellables for the service
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Initialization
    
    /// Private initializer for creating custom instances (for testing)
    private init(session: URLSession = .shared) {
        self.session = session
        
        #if DEBUG
        // Print the documents directory for debugging
        print("Documents Directory: \(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "Not found")")
        #endif
    }
    
    // MARK: - Public Methods
    
    // MARK: - LLMServiceProtocol Implementation
    
    @MainActor
    private func generateResponse(
        message: String,
        conversation: Conversation,
        systemPrompt: String,
        model: AIModel
    ) -> AnyPublisher<String, Error> {
        // Access messages on the main actor
        let history = conversation.messages.map { message in
            Message(
                id: message.id,
                content: message.content,
                timestamp: message.timestamp,
                isFromUser: message.isFromUser
            )
        }
        
        // Use the existing generateResponse method that takes a model and history
        return generateResponse(
            message: message,
            model: model,
            systemPrompt: systemPrompt,
            history: history
        )
    }
    
    @MainActor
    public func sendMessage(
        _ message: String,
        conversation: Conversation,
        systemPrompt: String,
        model: AIModel
    ) async throws -> String {
        // Create a copy of the messages to avoid capturing the conversation
        let messages = conversation.messages
        let history = messages.map { message in
            Message(
                id: message.id,
                content: message.content,
                timestamp: message.timestamp,
                isFromUser: message.isFromUser
            )
        }
        
        // Use the existing generateResponse method that takes a model and history
        return try await withCheckedThrowingContinuation { continuation in
            generateResponse(
                message: message,
                model: model,
                systemPrompt: systemPrompt,
                history: history
            )
            .receive(on: DispatchQueue.main) // Ensure we receive the response on the main thread
            .sink(
                receiveCompletion: { completion in
                    if case let .failure(error) = completion {
                        continuation.resume(throwing: error)
                    }
                },
                receiveValue: { response in
                    continuation.resume(returning: response)
                }
            )
            .store(in: &cancellables)
        }
    }
    
    public func generateResponse(
        message: String,
        model: AIModel,
        systemPrompt: String,
        history: [Message]
    ) -> AnyPublisher<String, Error> {
        if model.requiresAPIKey {
            return generateRemoteResponse(
                message: message,
                model: model,
                systemPrompt: systemPrompt,
                history: history
            )
        } else {
            return generateLocalResponse(
                message: message,
                model: model,
                systemPrompt: systemPrompt,
                history: history
            )
        }
    }
    
    public func generateResponse(
        prompt: String,
        model: String,
        conversationHistory: [Message],
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let aiModel = AIModel.allModels.first { $0.id == model } ?? defaultModel
        generateResponse(
            message: prompt,
            model: aiModel,
            systemPrompt: "",
            history: conversationHistory
        )
        .sink(receiveCompletion: { result in
            if case .failure(let error) = result {
                completion(.failure(error))
            }
        }, receiveValue: { response in
            completion(.success(response))
        })
        .store(in: &cancellables)
    }
    
    public func streamMessage(
        _ message: String,
        model: AIModel,
        systemPrompt: String,
        temperature: Double
    ) -> AnyPublisher<String, Error> {
        guard let baseURL = baseURL, let apiKey = apiKey, !apiKey.isEmpty else {
            return Fail(error: LLMError.invalidAPIKey).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        let requestBody: [String: Any] = [
            "model": model.id,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": message]
            ],
            "temperature": temperature,
            "stream": true
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }
        
        let subject = PassthroughSubject<String, Error>()
        
        let task = session.dataTask(with: request) { [subject] data, response, error in
            if let error = error {
                subject.send(completion: .failure(error))
                return
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                subject.send(completion: .failure(LLMError.invalidResponse))
                return
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                let errorMessage = "Request failed with status code: \(httpResponse.statusCode)"
                let error = NSError(
                    domain: "",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: errorMessage]
                )
                subject.send(completion: .failure(LLMError.requestFailed(error)))
                return
            }
            
            guard let data = data else {
                subject.send(completion: .failure(LLMError.noDataReceived))
                return
            }
            
            if let responseString = String(data: data, encoding: .utf8) {
                subject.send(responseString)
                subject.send(completion: .finished)
            } else {
                subject.send(completion: .failure(LLMError.invalidResponse))
            }
        }
        
        tasks.append(task)
        task.resume()
        
        return subject.eraseToAnyPublisher()
    }
    
    public func isModelAvailable(_ model: AIModel) -> Bool {
        if !model.requiresAPIKey, case let .localModel(_, path, _, _) = model {
            return FileManager.default.fileExists(atPath: path)
        }
        return true
    }
    
    public func availableModels() -> [AIModel] {
        return AIModel.allModels.filter { model in
            if model.requiresAPIKey {
                return true
            } else {
                return isModelAvailable(model)
            }
        }
    }
    
    public func cancelAllRequests() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }
    
    public func validateAPIKey(_ apiKey: String) -> Bool {
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    // MARK: - Private Methods
    
    private func generateLocalResponse(
        message: String,
        model: AIModel,
        systemPrompt: String,
        history: [Message]
    ) -> AnyPublisher<String, Error> {
        // Implementation for local models (e.g., Ollama, LLaMA.cpp, etc.)
        // This is a simplified implementation - you'll need to adapt it to your specific local model API
        
        guard let baseURL = baseURL else {
            return Fail(error: LLMError.invalidURL).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Prepare the request body for the local model
        let requestBody: [String: Any] = [
            "model": model.id,
            "prompt": message,
            "system": systemPrompt,
            "stream": false,
            "options": [
                "temperature": temperature,
                "top_p": topP,
                "num_predict": maxTokens,
                "repeat_penalty": 1.1,
                "stop": ["\n###", "\n\nUser:", "\n\n###"]
            ]
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }
        
        return session.dataTaskPublisher(for: request)
            .tryMap { data, response -> String in
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw LLMError.invalidResponse
                }
                
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw LLMError.requestFailed(NSError(domain: "", code: httpResponse.statusCode, userInfo: nil))
                }
                
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let responseText = json["response"] as? String else {
                    throw LLMError.decodingError(NSError(domain: "", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode response"]))
                }
                
                return responseText
            }
            .receive(on: DispatchQueue.main)
            .eraseToAnyPublisher()
    }
    
    private func generateRemoteResponse(
        message: String,
        model: AIModel,
        systemPrompt: String,
        history: [Message]
    ) -> AnyPublisher<String, Error> {
        // Implementation for remote models (e.g., OpenAI, Anthropic, etc.)
        
        guard let baseURL = baseURL, let apiKey = apiKey, !apiKey.isEmpty else {
            return Fail(error: LLMError.invalidAPIKey).eraseToAnyPublisher()
        }
        
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // Prepare the messages array
        var messages: [[String: String]] = []
        
        // Add system prompt if provided
        if !systemPrompt.isEmpty {
            messages.append(["role": "system", "content": systemPrompt])
        }
        
        // Add conversation history
        for msg in history {
            let role = msg.isFromUser ? "user" : "assistant"
            messages.append(["role": role, "content": msg.content])
        }
        
        // Add the current message
        messages.append(["role": "user", "content": message])
        
        // Prepare the request body
        let requestBody: [String: Any] = [
            "model": model.id,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "top_p": topP,
            "frequency_penalty": frequencyPenalty,
            "presence_penalty": presencePenalty,
            "stream": false
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
            
            return session.dataTaskPublisher(for: request)
                .tryMap { data, response -> String in
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw LLMError.invalidResponse
                    }
                    
                    guard (200...299).contains(httpResponse.statusCode) else {
                        let errorMessage: String
                        if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let error = errorJson["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            errorMessage = message
                        } else {
                            errorMessage = "Request failed with status code: \(httpResponse.statusCode)"
                        }
                        
                        throw LLMError.requestFailed(NSError(
                            domain: "",
                            code: httpResponse.statusCode,
                            userInfo: [NSLocalizedDescriptionKey: errorMessage]
                        ))
                    }
                    
                    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let firstChoice = choices.first,
                          let message = firstChoice["message"] as? [String: Any],
                          let content = message["content"] as? String else {
                        throw LLMError.decodingError(NSError(
                            domain: "",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Failed to decode response"]
                        ))
                    }
                    
                    return content
                }
                .receive(on: DispatchQueue.main)
                .eraseToAnyPublisher()
        } catch {
            return Fail(error: error).eraseToAnyPublisher()
        }
    }
    
    // MARK: - Helper Types
    
    private struct OpenAIResponse: Codable {
        struct Choice: Codable {
            struct Message: Codable {
                let content: String
            }
            let message: Message
        }
        let choices: [Choice]
    }
}
