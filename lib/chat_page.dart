import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'websocket_service.dart';

class ChatPage extends StatefulWidget {
  final String username;
  const ChatPage({super.key, required this.username});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _messageController = TextEditingController();
  final _scrollController = ScrollController();
  final WebSocketService _wsService = WebSocketService();
  final List<ChatMessage> _messages = [];

  // Reactions: messageId -> { emoji: count }
  final Map<int, Map<String, int>> _reactions = {};
  final Map<int, Set<String>> _myReactions = {};

  static const List<String> _availableReactions = [
    '👍',
    '❤️',
    '😂',
    '😮',
    '😥',
    '😡',
    '🔥',
    '🎉',
  ];

  List<Contact> _contacts = [];
  StreamSubscription? _contactsSub;
  StreamSubscription? _messageSub;
  StreamSubscription? _typingSub;
  StreamSubscription? _reactionsSub;
  StreamSubscription? _messageSentSub;

  Contact? _selectedContact;
  bool _showContacts = true;
  bool _isTyping = false;
  String? _typingUser;
  Timer? _typingTimer;
  Timer? _sendTypingTimer;
  Timer? _reactionFetchTimer;

  @override
  void initState() {
    super.initState();
    _contacts = List.from(_wsService.contacts);

    _contactsSub = _wsService.contactsStream.listen((contacts) {
      if (mounted) setState(() => _contacts = contacts);
    });

    _messageSub = _wsService.chatMessageStream.listen((msg) {
      if (!mounted) return;
      if (_selectedContact == null) return;

      final myEmail = _wsService.currentEmail ?? widget.username;

      // Skip real-time echoes of our own messages (already added locally)
      // But allow history messages from us
      if (!msg.isHistory && msg.senderEmail == myEmail) return;

      final isRelevant =
          (msg.senderEmail == _selectedContact!.email &&
              msg.receiverEmail == myEmail) ||
          (msg.senderEmail == myEmail &&
              msg.receiverEmail == _selectedContact!.email);

      if (isRelevant) {
        setState(() {
          if (!_messages.any((m) => m.id != null && m.id == msg.id)) {
            _messages.add(msg);
          }
        });
        _scrollToBottom();
        // Debounced batch fetch reactions after messages arrive
        _reactionFetchTimer?.cancel();
        _reactionFetchTimer = Timer(const Duration(milliseconds: 800), () {
          if (mounted) _fetchReactionsForMessages();
        });
      }
    });

    _typingSub = _wsService.typingStream.listen((data) {
      if (!mounted || _selectedContact == null) return;
      final email = data['user_email'] as String?;
      if (email == _selectedContact!.email) {
        setState(() {
          _isTyping = true;
          _typingUser = data['user_name'] as String? ?? _selectedContact!.name;
        });
        _typingTimer?.cancel();
        _typingTimer = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _isTyping = false);
        });
      }
    });

    // Listen for message_sent to update local message IDs
    _messageSentSub = _wsService.messageStream.listen((data) {
      if (!mounted) return;
      final event = data['event'] ?? data['type'] ?? data['action'];
      if (event == 'message_sent') {
        final msgId = data['message_id'] as int?;
        if (msgId != null) {
          setState(() {
            // Find the last local message without an id and assign it
            for (int i = _messages.length - 1; i >= 0; i--) {
              if (_messages[i].id == null) {
                _messages[i] = ChatMessage(
                  id: msgId,
                  senderEmail: _messages[i].senderEmail,
                  receiverEmail: _messages[i].receiverEmail,
                  groupId: _messages[i].groupId,
                  text: _messages[i].text,
                  messageType: _messages[i].messageType,
                  createdAt: _messages[i].createdAt,
                  senderName: _messages[i].senderName,
                  isHistory: _messages[i].isHistory,
                );
                break;
              }
            }
          });
          // Fetch reactions for this message (it may already have reactions from web)
          _wsService.getReactions(messageIds: [msgId]);
        }
      }
    });

    _reactionsSub = _wsService.reactionsStream.listen((data) {
      if (!mounted) return;
      final event = data['event'];
      debugPrint('[ChatPage] Reaction event: $event, data keys: ${data.keys}');

      if (event == 'reactions') {
        _parseReactionsMap(data['reactions']);
      } else if (event == 'reaction_updated') {
        final msgId = data['message_id'] as int?;
        debugPrint('[ChatPage] Reaction updated for msg $msgId');
        if (msgId != null) {
          // If the event contains reaction details, apply directly
          final reactions = data['reactions'];
          if (reactions is Map && reactions.isNotEmpty) {
            _parseReactionsMap(reactions);
          }
          // Always re-fetch to get accurate state
          _wsService.getReactions(messageIds: [msgId]);
        }
      }
    });

    // Request contacts if we don't have them yet
    if (_contacts.isEmpty) {
      _wsService.getContacts();
    }
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty || _selectedContact == null) return;

    final myEmail = _wsService.currentEmail ?? widget.username;

    // Send via WebSocket
    _wsService.sendChatMessage(
      senderEmail: myEmail,
      receiverEmail: _selectedContact!.email,
      messageText: text,
    );

    // Add to local list immediately
    setState(() {
      _messages.add(
        ChatMessage(
          senderEmail: myEmail,
          receiverEmail: _selectedContact!.email,
          text: text,
          createdAt: DateTime.now(),
        ),
      );
      _messageController.clear();
    });

    _scrollToBottom();
  }

  void _onTextChanged(String text) {
    if (_selectedContact == null) return;
    // Send typing indicator (throttled)
    if (_sendTypingTimer == null || !_sendTypingTimer!.isActive) {
      _wsService.sendTyping(
        userEmail: _wsService.currentEmail ?? widget.username,
        otherEmail: _selectedContact!.email,
      );
      _sendTypingTimer = Timer(const Duration(seconds: 3), () {});
    }
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _selectContact(Contact contact) {
    setState(() {
      _selectedContact = contact;
      _showContacts = false;
      _messages.clear();
      _reactions.clear();
      _myReactions.clear();
      _isTyping = false;
    });

    // Load message history
    final myEmail = _wsService.currentEmail ?? widget.username;
    _wsService.getMessages(userEmail: myEmail, otherEmail: contact.email);

    // Mark as read
    _wsService.markRead(userEmail: myEmail, otherEmail: contact.email);
  }

  void _parseReactionsMap(dynamic reactionsMap) {
    if (reactionsMap is! Map) return;
    final myEmail = _wsService.currentEmail ?? widget.username;
    setState(() {
      for (final entry in reactionsMap.entries) {
        final msgId = int.tryParse(entry.key.toString());
        if (msgId == null) continue;
        final reactionsList = entry.value as List<dynamic>? ?? [];
        final counts = <String, int>{};
        final mine = <String>{};
        for (final r in reactionsList) {
          final emoji = r['reaction'] as String? ?? '';
          final count = r['count'] as int? ?? 1;
          counts[emoji] = count;
          final userEmails = r['user_emails'] as List<dynamic>? ?? [];
          if (userEmails.contains(myEmail)) {
            mine.add(emoji);
          }
        }
        _reactions[msgId] = counts;
        _myReactions[msgId] = mine;
      }
    });
  }

  void _fetchReactionsForMessages() {
    final ids = _messages.where((m) => m.id != null).map((m) => m.id!).toList();
    if (ids.isNotEmpty) {
      _wsService.getReactions(messageIds: ids);
    }
  }

  void _showReactionPicker(ChatMessage msg) {
    if (msg.id == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 20,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'React to message',
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF8A96B0),
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: _availableReactions.map((emoji) {
                  final isSelected =
                      _myReactions[msg.id]?.contains(emoji) ?? false;
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      _toggleReaction(msg.id!, emoji);
                    },
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF3B6FE8).withValues(alpha: 0.15)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                        border: isSelected
                            ? Border.all(
                                color: const Color(0xFF3B6FE8),
                                width: 1.5,
                              )
                            : null,
                      ),
                      child: Text(emoji, style: const TextStyle(fontSize: 28)),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        );
      },
    );
  }

  void _toggleReaction(int messageId, String emoji) {
    final myEmail = _wsService.currentEmail ?? widget.username;
    _wsService.toggleReaction(
      messageId: messageId,
      userEmail: myEmail,
      reaction: emoji,
    );

    // Optimistic update
    setState(() {
      final mine = _myReactions[messageId] ?? {};
      final counts = _reactions[messageId] ?? {};
      if (mine.contains(emoji)) {
        mine.remove(emoji);
        counts[emoji] = (counts[emoji] ?? 1) - 1;
        if (counts[emoji]! <= 0) counts.remove(emoji);
      } else {
        mine.add(emoji);
        counts[emoji] = (counts[emoji] ?? 0) + 1;
      }
      _myReactions[messageId] = mine;
      _reactions[messageId] = counts;
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _contactsSub?.cancel();
    _messageSub?.cancel();
    _typingSub?.cancel();
    _reactionsSub?.cancel();
    _messageSentSub?.cancel();
    _typingTimer?.cancel();
    _reactionFetchTimer?.cancel();
    _sendTypingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5FA),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A2035),
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (!_showContacts && _selectedContact != null) {
              setState(() {
                _showContacts = true;
                _selectedContact = null;
                _messages.clear();
                _reactions.clear();
                _myReactions.clear();
                _isTyping = false;
              });
            } else {
              Navigator.pop(context);
            }
          },
        ),
        title: _showContacts
            ? const Text(
                'Team Chat',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              )
            : Row(
                children: [
                  Stack(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: const Color(0xFF3B6FE8),
                        child: Text(
                          _selectedContact!.name[0],
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: _selectedContact!.online
                                ? Colors.green
                                : Colors.grey,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 1.5),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _selectedContact!.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          _isTyping
                              ? 'typing...'
                              : _selectedContact!.online
                              ? 'Online'
                              : 'Offline',
                          style: TextStyle(
                            fontSize: 11,
                            color: _isTyping
                                ? Colors.greenAccent
                                : Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
      body: _showContacts ? _buildContactList() : _buildChatView(),
    );
  }

  Widget _buildContactList() {
    if (_contacts.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.people_outline, size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            Text(
              _wsService.currentStatus == ConnectionStatus.connected
                  ? 'Loading contacts...'
                  : 'Connect to see contacts',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade500,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _wsService.getContacts(),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Refresh'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF3B6FE8),
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      );
    }

    // Sort: online first
    final sorted = List<Contact>.from(_contacts)
      ..sort((a, b) {
        if (a.online && !b.online) return -1;
        if (!a.online && b.online) return 1;
        return a.name.compareTo(b.name);
      });

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: sorted.length,
      itemBuilder: (context, index) {
        final contact = sorted[index];
        // Skip self
        if (contact.email == _wsService.currentEmail)
          return const SizedBox.shrink();

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 6,
            ),
            leading: Stack(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: const Color(
                    0xFF3B6FE8,
                  ).withValues(alpha: 0.1),
                  child: Text(
                    contact.name[0].toUpperCase(),
                    style: const TextStyle(
                      color: Color(0xFF3B6FE8),
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: contact.online
                          ? Colors.green
                          : Colors.grey.shade400,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            title: Text(
              contact.name,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 15,
                color: Color(0xFF1A2035),
              ),
            ),
            subtitle: Text(
              contact.email,
              style: const TextStyle(fontSize: 12, color: Color(0xFF8A96B0)),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (contact.online)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'Online',
                      style: TextStyle(
                        color: Colors.green,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chat_bubble_outline,
                  color: const Color(0xFF3B6FE8).withValues(alpha: 0.6),
                  size: 20,
                ),
              ],
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            onTap: () => _selectContact(contact),
          ),
        );
      },
    );
  }

  Widget _buildChatView() {
    final myEmail = _wsService.currentEmail ?? widget.username;

    return Column(
      children: [
        // Messages list
        Expanded(
          child: _messages.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.chat_bubble_outline,
                        size: 48,
                        color: Colors.grey.shade400,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Start a conversation with ${_selectedContact?.name ?? ""}',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: _messages.length + (_isTyping ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (_isTyping && index == _messages.length) {
                      return _buildTypingIndicator();
                    }
                    final msg = _messages[index];
                    final isMe = msg.senderEmail == myEmail;
                    return _buildMessageBubble(msg, isMe);
                  },
                ),
        ),

        // Message input
        Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: SafeArea(
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendMessage(),
                    onChanged: _onTextChanged,
                    decoration: InputDecoration(
                      hintText: 'Type a message...',
                      hintStyle: const TextStyle(
                        color: Color(0xFFB0BAD0),
                        fontSize: 14,
                      ),
                      filled: true,
                      fillColor: const Color(0xFFF3F5FA),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  decoration: const BoxDecoration(
                    color: Color(0xFF3B6FE8),
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.send, color: Colors.white, size: 20),
                    onPressed: _sendMessage,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTypingIndicator() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${_typingUser ?? "Someone"} is typing',
              style: const TextStyle(
                color: Color(0xFF8A96B0),
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
            const SizedBox(width: 4),
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Color(0xFF8A96B0),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage msg, bool isMe) {
    final timeStr = DateFormat('hh:mm a').format(msg.createdAt);
    final msgReactions = msg.id != null ? _reactions[msg.id] : null;
    final hasReactions = msgReactions != null && msgReactions.isNotEmpty;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _showReactionPicker(msg),
        onDoubleTap: () => _showReactionPicker(msg),
        child: Container(
          margin: EdgeInsets.only(bottom: hasReactions ? 4 : 10),
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.75,
          ),
          child: Column(
            crossAxisAlignment: isMe
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            children: [
              // Message bubble
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: isMe ? const Color(0xFF3B6FE8) : Colors.white,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: Radius.circular(isMe ? 16 : 4),
                    bottomRight: Radius.circular(isMe ? 4 : 16),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 5,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: isMe
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    if (!isMe && msg.senderName != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          msg.senderName!,
                          style: const TextStyle(
                            color: Color(0xFF3B6FE8),
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    Text(
                      msg.text,
                      style: TextStyle(
                        color: isMe ? Colors.white : const Color(0xFF1A2035),
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      timeStr,
                      style: TextStyle(
                        color: isMe ? Colors.white70 : const Color(0xFF8A96B0),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),

              // Reactions row
              if (hasReactions)
                Transform.translate(
                  offset: const Offset(0, -6),
                  child: Container(
                    margin: EdgeInsets.only(
                      left: isMe ? 0 : 8,
                      right: isMe ? 8 : 0,
                      bottom: 6,
                    ),
                    child: Wrap(
                      spacing: 4,
                      children: msgReactions.entries.map((entry) {
                        final emoji = entry.key;
                        final count = entry.value;
                        final isMine =
                            _myReactions[msg.id]?.contains(emoji) ?? false;
                        return GestureDetector(
                          onTap: () => _toggleReaction(msg.id!, emoji),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: isMine
                                  ? const Color(
                                      0xFF3B6FE8,
                                    ).withValues(alpha: 0.15)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isMine
                                    ? const Color(
                                        0xFF3B6FE8,
                                      ).withValues(alpha: 0.4)
                                    : Colors.grey.withValues(alpha: 0.3),
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.05),
                                  blurRadius: 2,
                                ),
                              ],
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  emoji,
                                  style: const TextStyle(fontSize: 14),
                                ),
                                if (count > 1) ...[
                                  const SizedBox(width: 2),
                                  Text(
                                    '$count',
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: isMine
                                          ? const Color(0xFF3B6FE8)
                                          : const Color(0xFF8A96B0),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
