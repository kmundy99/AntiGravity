import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../secrets.dart';
import 'ai_prompts.dart';

void showFeedbackModal(
  BuildContext context,
  String? userId,
  String? displayName,
  String screenContext,
) {
  String type = "Help/Question";
  String description = "";
  bool isSubmitting = false;
  String aiResponse = "";

  final TextEditingController textController = TextEditingController();

  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setModalState) {
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
              left: 20,
              right: 20,
              top: 20,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Feedback & Support",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: "Help/Question",
                      label: Text("Question"),
                    ),
                    ButtonSegment(
                      value: "Feature Request",
                      label: Text("Idea"),
                    ),
                    ButtonSegment(value: "Bug Report", label: Text("Bug")),
                  ],
                  selected: {type},
                  onSelectionChanged: (set) => setModalState(() {
                    type = set.first;
                    aiResponse = "";
                  }),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: textController,
                  decoration: InputDecoration(
                    labelText: type == "Help/Question"
                        ? "How can I help you?"
                        : type == "Bug Report"
                        ? "Describe what went wrong..."
                        : "Describe your feature idea...",
                    border: const OutlineInputBorder(),
                  ),
                  maxLines: 4,
                  onChanged: (val) => description = val,
                ),
                const SizedBox(height: 16),
                if (aiResponse.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      "🤖 AI: $aiResponse",
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade900,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: isSubmitting
                        ? null
                        : () async {
                            if (description.trim().isEmpty) return;
                            setModalState(() => isSubmitting = true);

                            String finalAiResponse = "";

                            if (type == "Help/Question") {
                              try {
                                final response = await http.post(
                                  Uri.parse(
                                    'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$geminiApiKey',
                                  ),
                                  headers: {'Content-Type': 'application/json'},
                                  body: jsonEncode({
                                    "system_instruction": {
                                      "parts": [
                                        {
                                          "text":
                                              AiPrompts.feedbackAssistantGuide,
                                        },
                                      ],
                                    },
                                    "contents": [
                                      {
                                        "parts": [
                                          {"text": description},
                                        ],
                                      },
                                    ],
                                  }),
                                );

                                if (response.statusCode == 200) {
                                  final data = jsonDecode(response.body);
                                  finalAiResponse =
                                      data['candidates'][0]['content']['parts'][0]['text'] ??
                                      "I'm sorry, I couldn't process that.";
                                } else {
                                  finalAiResponse =
                                      "Error connecting to AI assistant: \${response.statusCode}";
                                }

                                setModalState(
                                  () => aiResponse = finalAiResponse,
                                );
                              } catch (e) {
                                setModalState(
                                  () => aiResponse =
                                      "Error connecting to AI assistant.",
                                );
                              }
                            }

                            await FirebaseFirestore.instance
                                .collection('feedbacks')
                                .add({
                                  'userId': userId,
                                  'displayName': displayName,
                                  'type': type,
                                  'description': description,
                                  'aiResponse': finalAiResponse,
                                  'screenContext': screenContext,
                                  'createdAt': FieldValue.serverTimestamp(),
                                });

                            setModalState(() => isSubmitting = false);

                            if (type != "Help/Question") {
                              if (context.mounted) {
                                Navigator.pop(context);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text(
                                      "Feedback Logged! Thank you.",
                                    ),
                                  ),
                                );
                              }
                            }
                          },
                    child: isSubmitting
                        ? const CircularProgressIndicator(color: Colors.white)
                        : Text(
                            type == "Help/Question"
                                ? (aiResponse.isEmpty
                                      ? "Ask AI"
                                      : "Ask Another")
                                : "Submit",
                          ),
                  ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          );
        },
      );
    },
  );
}
