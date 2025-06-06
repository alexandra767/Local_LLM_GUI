import SwiftUI
import Combine
import Foundation
import AppKit
import LLMService

@MainActor
struct ChatView: View {
    // MARK: - Properties
    
    @ObservedObject var conversation: Conversation
    @State private var messageText: String = ""
    @State private var isProcessing: Bool = false
    @State private var systemPrompt: String = "You are a helpful AI assistant."
    @State private var selectedModel: AIModel = AIModel.defaultModel
    @State private var cancellables = Set<AnyCancellable>()
    @State private var errorMessage: String? = nil
    @State private var showingError: Bool = false
    @EnvironmentObject private var appState: AppState
    
    // MARK: - Initialization
    
    init(conversation: Conversation) {
        self.conversation = conversation
        _systemPrompt = State(initialValue: conversation.systemPrompt)
    }
    
    // MARK: - Message Handling
    
    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        
        // Create and add user message
        let userMessage = Message(
            content: text,
            timestamp: Date(),
            isFromUser: true
        )
        
        conversation.addMessage(userMessage)
        messageText = ""
        
        // Process AI response
        processAIResponse()
    }
    
    private func processAIResponse() {
        guard let lastUserMessage = conversation.messages.last(where: { $0.isFromUser }) else {
            print("No user message found to process")
            return
        }
        
        isProcessing = true
        
        // Create a placeholder for the AI response
        let responseMessage = Message(
            content: "",
            timestamp: Date(),
            isFromUser: false
        )
        
        // Add the response message to the conversation
        conversation.addMessage(responseMessage)
        
        // Get the response from the LLM service
        let cancellable = appState.llmService.generateResponse(
            message: lastUserMessage.content,
            model: selectedModel,
            systemPrompt: systemPrompt,
            history: conversation.messages
        )
        .receive(on: DispatchQueue.main)
        .sink(
            receiveCompletion: { completion in
                self.isProcessing = false
                
                if case .failure(let error) = completion {
                    // Display the error message to the user
                    self.errorMessage = error.localizedDescription
                    self.showingError = true
                    
                    // Update the last message to indicate an error
                    if let lastIndex = self.conversation.messages.lastIndex(where: { $0.id == responseMessage.id }) {
                        self.conversation.messages[lastIndex].content = "Failed to generate response. Please try again."
                        self.conversation.messages[lastIndex].status = .failed
                    }
                    
                    print("Error generating response: \(error.localizedDescription)")
                }
            },
            receiveValue: { response in
                // Update the message with the AI's response
                if let lastIndex = self.conversation.messages.lastIndex(where: { $0.id == responseMessage.id }) {
                    self.conversation.messages[lastIndex].content = response
                    self.conversation.messages[lastIndex].status = .delivered
                }
            }
        )
        
        cancellables.insert(cancellable)
    }
    
    // MARK: - View Components
    
    private var chatMessagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(conversation.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                            .padding(.vertical, 4)
                    }
                }
                .padding()
            }
            .onChange(of: conversation.messages) { _ in
                if let lastMessage = conversation.messages.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
    
    private func promptUserWithAlert() {
        let alert = NSAlert()
        alert.messageText = "Type your message"
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        
        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        alert.accessoryView = textField
        
        // Focus the text field
        DispatchQueue.main.async {
            alert.window?.makeFirstResponder(textField)
        }
        
        if alert.runModal() == .alertFirstButtonReturn {
            let text = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                messageText = text
                sendMessage()
            }
        }
    }
    
    private var modelPicker: some View {
        HStack {
            Picker("Model", selection: $selectedModel) {
                ForEach(AIModel.allModels) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(MenuPickerStyle())
            .frame(width: 200)
            
            Button(action: {
                Task {
                    await appState.llmService.scanForLocalModels()
                    // Refresh the selectedModel after scanning
                    if let defaultModel = AIModel.allModels.first {
                        selectedModel = defaultModel
                    }
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Refresh model list")
        }
    }
    
    // MARK: - Body
    
    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                modelPicker
                Spacer()
                
                Button(action: showSettings) {
                    Image(systemName: "gear")
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            // Main chat area
            chatMessagesView
            
            // Button to open standalone window for reliable input
            VStack(spacing: 0) {
                Divider()
                
                HStack {
                    Button(action: {
                        // Open standalone window
                        conversation.openInStandaloneWindow(with: appState)
                    }) {
                        HStack {
                            Text("💬 Open in new window for better typing")
                                .foregroundColor(.accentColor)
                            Spacer()
                        }
                        .padding()
                    }
                    .buttonStyle(BorderedButtonStyle())
                    
                    Button(action: promptUserWithAlert) {
                        Text("📝 Or use dialog")
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
            }
        }
        .navigationTitle(conversation.title)
        .alert("Error", isPresented: $showingError) {
            Button("OK") {
                showingError = false
            }
        } message: {
            Text(errorMessage ?? "An unknown error occurred")
        }
        .onAppear {
            // Make sure there's at least one message in the conversation
            if conversation.messages.isEmpty {
                let welcomeMessage = Message(
                    content: "Welcome! How can I help you today?",
                    timestamp: Date(),
                    isFromUser: false,
                    status: .delivered
                )
                conversation.addMessage(welcomeMessage)
            }
            
            // Load system prompt if available
            if !conversation.systemPrompt.isEmpty {
                systemPrompt = conversation.systemPrompt
            }
        }
    }
    
    private func showSettings() {
        let settingsView = NavigationView {
            Form {
                Section(header: Text("System Prompt")) {
                    TextEditor(text: $systemPrompt)
                        .frame(height: 100)
                }
                
                Section(header: Text("Model Settings")) {
                    Picker("Model", selection: $selectedModel) {
                        ForEach(AIModel.allCases.filter { !$0.requiresAPIKey }) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                }
            }
            .padding()
            .frame(width: 500, height: 400)
        }
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.title = "Chat Settings"
        window.contentView = NSHostingView(rootView: settingsView)
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Message View

struct MessageBubble: View {
    let message: Message
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !message.isFromUser {
                Image(systemName: "bubble.left.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 16))
                    .padding(.top, 2)
            }
            
            if message.isFromUser {
                Spacer()
                Text(message.content)
                    .padding(12)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .contextMenu {
                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                        }) {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.content)
                        .padding(12)
                        .background(Color(NSColor.controlBackgroundColor))
                        .foregroundColor(Color(NSColor.textColor))
                        .cornerRadius(12)
                        .contextMenu {
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.content, forType: .string)
                            }) {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }
                    
                    if message.status == .sending {
                        ProgressView()
                            .scaleEffect(0.5)
                            .padding(.leading, 8)
                    } else if message.status == .failed {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .font(.caption)
                            Text("Failed to send")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(.leading, 8)
                    }
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .transition(.opacity)
        .animation(.easeInOut, value: message.id)
    }
}

// MARK: - Preview

#if DEBUG
struct ChatView_Previews: PreviewProvider {
    static var previews: some View {
        let conversation = Conversation(
            title: "Preview Conversation",
            messages: [
                Message(
                    id: UUID(),
                    content: "Hello, how can I help you today?",
                    timestamp: Date(),
                    isFromUser: true,
                    status: .sent
                ),
                Message(
                    id: UUID(),
                    content: "I'm doing well, thank you for asking! How can I assist you?",
                    timestamp: Date(),
                    isFromUser: false,
                    status: .sent
                )
            ]
        )
        return ChatView(conversation: conversation)
            .environmentObject(AppState.shared)
            .frame(width: 400, height: 600)
    }
}
#endif