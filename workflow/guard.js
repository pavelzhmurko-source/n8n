const update = $json.body ?? $json;
const allowedUserIds = new Set(__ALLOWED_USER_IDS_JSON__.map(String));

if (!Number.isSafeInteger(update.update_id)) {
  return [];
}

const message = update.message;
if (!message || message.chat?.type !== 'private' || typeof message.text !== 'string') {
  return [];
}

const userId = String(message.from?.id ?? '');
if (!allowedUserIds.has(userId)) {
  return [];
}

const staticData = $getWorkflowStaticData('global');
if (!Array.isArray(staticData.processedUpdateIds)) {
  staticData.processedUpdateIds = [];
}

const updateId = String(update.update_id);
if (staticData.processedUpdateIds.includes(updateId)) {
  return [];
}

staticData.processedUpdateIds.push(updateId);
if (staticData.processedUpdateIds.length > 1000) {
  staticData.processedUpdateIds = staticData.processedUpdateIds.slice(-1000);
}

const normalizedText = message.text.replace(/\s+/g, ' ').trim().slice(0, 3500);
return [{
  json: {
    chatId: String(message.chat.id),
    replyText: `Отримано: ${normalizedText}`,
  },
}];
