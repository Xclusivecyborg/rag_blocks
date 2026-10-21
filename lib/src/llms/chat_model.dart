import 'dart:convert';

/// One message in a conversation with a chat model.
class ChatMessage {
  const ChatMessage(
    this.role,
    this.content, {
    this.toolCalls = const [],
    this.toolName,
  });

  /// The result of running [call], to send back to the model.
  ChatMessage.toolResult(ToolCall call, this.content)
    : role = 'tool',
      toolCalls = const [],
      toolName = call.name;

  final String role; // 'system', 'user', 'assistant' or 'tool'
  final String content;

  /// The tools an assistant message asked to run.
  final List<ToolCall> toolCalls;

  /// For a 'tool' message, the tool whose result [content] is.
  final String? toolName;

  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    if (toolCalls.isNotEmpty)
      'tool_calls': [for (final call in toolCalls) call.toJson()],
    'tool_name': ?toolName,
  };
}

/// A tool the model may ask to run, described the way Ollama and OpenAI
/// expect: a name, what it does, and its arguments as a JSON Schema.
class Tool {
  const Tool({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;

  /// Tells the model when to use the tool. It decides from this alone.
  final String description;

  /// A JSON Schema object describing the arguments.
  final Map<String, dynamic> parameters;

  Map<String, dynamic> toJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

/// A model's request to run a [Tool] with [arguments].
class ToolCall {
  const ToolCall(this.name, this.arguments);

  final String name;
  final Map<String, dynamic> arguments;

  /// Reads one entry of a reply's `tool_calls`. Arguments may arrive as an
  /// object (Ollama) or as a JSON string (OpenAI); unreadable ones are empty.
  factory ToolCall.fromJson(Map<String, dynamic> json) {
    final function = json['function'] as Map<String, dynamic>? ?? const {};
    final name = function['name'] as String? ?? '';
    final raw = function['arguments'];
    if (raw is Map<String, dynamic>) return ToolCall(name, raw);
    if (raw is String) {
      try {
        return ToolCall(name, jsonDecode(raw) as Map<String, dynamic>);
      } on Object {
        // Falls through to no arguments; the tool reports what is missing.
      }
    }
    return ToolCall(name, const {});
  }

  Map<String, dynamic> toJson() => {
    'function': {'name': name, 'arguments': arguments},
  };
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
