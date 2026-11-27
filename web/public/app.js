const storageKey = "lark-consultant-browser-messages";
const form = document.querySelector("#chat-form");
const promptInput = document.querySelector("#prompt");
const sendButton = document.querySelector("#send-button");
const imageInput = document.querySelector("#image-input");
const messagesElement = document.querySelector("#messages");
const welcomeElement = document.querySelector("#welcome");
const errorElement = document.querySelector("#error-message");
const attachmentElement = document.querySelector("#attachment-list");
let messages = loadMessages();
let attachments = [];
let isSending = false;

function loadMessages() {
  try {
    const parsed = JSON.parse(localStorage.getItem(storageKey) || "[]");
    return Array.isArray(parsed) ? parsed.filter((message) =>
      ["user", "assistant"].includes(message?.role)
      && (typeof message.content === "string" || Array.isArray(message.content))
    ) : [];
  } catch {
    return [];
  }
}

function saveMessages() {
  try {
    localStorage.setItem(storageKey, JSON.stringify(messages));
  } catch {
    showError("Your browser couldn't save this conversation. You can continue chatting, but it may not persist.");
  }
}

function showError(message = "") {
  errorElement.textContent = message;
  errorElement.hidden = !message;
}

function messageText(content) {
  if (typeof content === "string") return content;
  return content.filter((part) => part?.type === "text").map((part) => part.text).join("");
}

function renderMessages() {
  messagesElement.replaceChildren();
  welcomeElement.hidden = messages.length > 0;
  for (const message of messages) {
    const row = document.createElement("article");
    row.className = `message ${message.role}`;
    const avatar = document.createElement("div");
    avatar.className = "avatar";
    avatar.textContent = message.role === "assistant" ? "L" : "Y";
    const body = document.createElement("div");
    body.className = "message-body";
    const label = document.createElement("div");
    label.className = "message-label";
    label.textContent = message.role === "assistant" ? "Lark" : "You";
    body.append(label);
    const text = messageText(message.content);
    if (text) {
      const paragraph = document.createElement("div");
      paragraph.className = "message-text";
      paragraph.textContent = text;
      body.append(paragraph);
    }
    const imageParts = typeof message.content === "string"
      ? []
      : message.content.filter((part) => part?.type === "image_url" && typeof part.image_url?.url === "string");
    if (imageParts.length) {
      const images = document.createElement("div");
      images.className = "message-images";
      for (const part of imageParts) {
        const image = document.createElement("img");
        image.src = part.image_url.url;
        image.alt = "Attached image";
        images.append(image);
      }
      body.append(images);
    }
    row.append(avatar, body);
    messagesElement.append(row);
  }
  document.querySelector("#conversation").scrollTop = document.querySelector("#conversation").scrollHeight;
}

function updateSendButton() {
  sendButton.disabled = isSending || (!promptInput.value.trim() && attachments.length === 0);
}

function updateAttachments() {
  attachmentElement.replaceChildren();
  attachmentElement.hidden = attachments.length === 0;
  if (!attachments.length) return;
  const label = document.createElement("span");
  label.textContent = `${attachments.length} image${attachments.length === 1 ? "" : "s"} attached`;
  const remove = document.createElement("button");
  remove.type = "button";
  remove.textContent = "Remove";
  remove.addEventListener("click", () => {
    attachments = [];
    imageInput.value = "";
    updateAttachments();
    updateSendButton();
  });
  attachmentElement.append(label, remove);
}

async function fileToDataURL(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = () => reject(new Error(`Couldn't read ${file.name}.`));
    reader.readAsDataURL(file);
  });
}

imageInput.addEventListener("change", async () => {
  showError();
  const files = Array.from(imageInput.files || []);
  if (attachments.length + files.length > 6) {
    showError("Please attach no more than 6 images.");
    imageInput.value = "";
    return;
  }
  try {
    for (const file of files) {
      if (!["image/jpeg", "image/png", "image/gif", "image/webp"].includes(file.type)) {
        throw new Error("Please choose JPEG, PNG, GIF, or WebP images.");
      }
      if (file.size > 5 * 1024 * 1024) throw new Error("Each image must be smaller than 5 MB.");
      attachments.push({ type: "image_url", image_url: { url: await fileToDataURL(file) } });
    }
    updateAttachments();
  } catch (error) {
    showError(error.message);
  }
  imageInput.value = "";
  updateSendButton();
});

promptInput.addEventListener("input", () => {
  promptInput.style.height = "auto";
  promptInput.style.height = `${Math.min(promptInput.scrollHeight, 150)}px`;
  updateSendButton();
});

promptInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    if (!sendButton.disabled) form.requestSubmit();
  }
});

document.querySelectorAll(".suggestion").forEach((button) => {
  button.addEventListener("click", () => {
    promptInput.value = button.textContent;
    promptInput.focus();
    updateSendButton();
  });
});

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const text = promptInput.value.trim();
  if (isSending || (!text && attachments.length === 0)) return;
  const content = [...(text ? [{ type: "text", text }] : []), ...attachments];
  messages.push({ role: "user", content });
  attachments = [];
  promptInput.value = "";
  promptInput.style.height = "auto";
  updateAttachments();
  isSending = true;
  showError();
  updateSendButton();
  renderMessages();
  const typing = document.createElement("article");
  typing.className = "message";
  typing.innerHTML = '<div class="avatar">L</div><div class="message-body"><div class="message-label">Lark</div><div class="typing">Thinking…</div></div>';
  messagesElement.append(typing);
  document.querySelector("#conversation").scrollTop = document.querySelector("#conversation").scrollHeight;

  try {
    const response = await fetch("/api/chat", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ messages }),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || `Request failed (${response.status}).`);
    messages.push({ role: "assistant", content: result.reply });
    saveMessages();
  } catch (error) {
    showError(error.message || "Couldn't send your message. Please try again.");
  } finally {
    isSending = false;
    updateSendButton();
    renderMessages();
  }
});

function clearConversation() {
  messages = [];
  attachments = [];
  localStorage.removeItem(storageKey);
  updateAttachments();
  updateSendButton();
  showError();
  renderMessages();
}

document.querySelector("#new-chat").addEventListener("click", clearConversation);
document.querySelector("#clear-chat").addEventListener("click", clearConversation);

async function checkConnection() {
  let configured = false;
  try {
    const response = await fetch("/api/config");
    configured = response.ok && (await response.json()).configured;
  } catch {
    configured = false;
  }
  const dotClass = configured ? "online" : "offline";
  for (const id of ["status-dot", "mobile-status-dot"]) {
    document.querySelector(`#${id}`).classList.add(dotClass);
  }
  document.querySelector("#status-label").textContent = configured ? "Ready to chat" : "Server setup needed";
  document.querySelector("#mobile-status-label").textContent = configured ? "Ready" : "Offline";
  if (!configured) {
    showError("Live chat isn't configured. Set LARK_AI_ENDPOINT and LARK_AI_API_KEY on the server.");
  }
}

renderMessages();
updateSendButton();
checkConnection();
