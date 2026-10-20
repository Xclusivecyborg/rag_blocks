/// One message in a conversation with a chat model.
class ChatMessage {
  const ChatMessage(this.role, this.content);
  final String role; // 'system', 'user' or 'assistant'
  final String content;

  Map<String, dynamic> toJson() => {'role': role, 'content': content};
}

/// A model that writes a reply to a conversation.
///
/// `QueryCondenser` takes any [ChatModel]. Use `ollama.chatModel('llama3.2')`
/// for Ollama, or implement this to use another model, such as one that runs
/// on a phone:
///
/// ```dart
/// class OnDeviceChat implements ChatModel {
///   @override
///   Future<String> reply(
///     List<ChatMessage> messages, {
///     double temperature = 0.2,
///   }) => myModel.generate(messages, temperature: temperature);
/// }
/// ```
abstract interface class ChatModel {
  /// The whole reply to [messages].
  ///
  /// [temperature] is how much the wording may vary: 0 gives the most
  /// predictable reply. Models that have no such setting can ignore it.
  Future<String> reply(List<ChatMessage> messages, {double temperature = 0.2});
}
