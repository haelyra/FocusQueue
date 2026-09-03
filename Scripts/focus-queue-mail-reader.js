ObjC.import("Foundation");

const CONFIG_PATH = "/Users/hira/Library/Application Support/ECC Focus Queue/ingestion.json";
const RUNTIME_PATH = "/Users/hira/Library/Application Support/ECC Focus Queue/ingestion";
const REQUEST_PATH = `${RUNTIME_PATH}/mail-request.json`;
const RESPONSE_PATH = `${RUNTIME_PATH}/mail-response.json`;
const CONNECTOR = "ecc-focus-mail-reader";
const MAX_BODY_CHARACTERS = 100000;
const MAX_SEARCH_CANDIDATES = 5000;
const MAX_BODY_SEARCH_CANDIDATES = 250;

function safeValue(operation, fallback) {
  try {
    const value = operation();
    return value === undefined || value === null ? fallback : value;
  } catch (_) {
    return fallback;
  }
}

function readJSON(path) {
  const contents = $.NSString.stringWithContentsOfFileEncodingError(
    $(path).stringByStandardizingPath,
    $.NSUTF8StringEncoding,
    null
  );
  if (!contents) throw new Error(`Could not read ${path}`);
  return JSON.parse(ObjC.unwrap(contents));
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

function writePrivateJSON(path, payload) {
  const encoded = JSON.stringify(payload, null, 2) + "\n";
  const written = $(encoded).writeToFileAtomicallyEncodingError(
    $(path).stringByStandardizingPath,
    true,
    $.NSUTF8StringEncoding,
    null
  );
  if (!written) throw new Error(`Could not write ${path}`);
  const app = Application.currentApplication();
  app.includeStandardAdditions = true;
  app.doShellScript(`/bin/chmod 600 ${shellQuote(path)}`);
}

function isoNow() {
  return new Date().toISOString();
}

function normalizedMessageId(value) {
  const cleaned = String(value || "").trim();
  if (!cleaned) return "";
  return cleaned.startsWith("<") ? cleaned : `<${cleaned}>`;
}

function messageURL(messageId) {
  return messageId ? `message://${encodeURIComponent(normalizedMessageId(messageId))}` : "";
}

function cleanText(value, limit) {
  const text = String(value || "")
    .replace(/\u0000/g, "")
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .trim();
  return text.length > limit ? text.slice(0, limit) : text;
}

function recipientAddresses(message) {
  const result = [];
  for (const property of ["toRecipients", "ccRecipients", "bccRecipients"]) {
    for (const recipient of safeValue(() => message[property](), [])) {
      const address = safeValue(() => recipient.address(), "");
      if (address) result.push(String(address).toLowerCase());
    }
  }
  return result;
}

function belongsToAddress(message, targetAddress) {
  if (recipientAddresses(message).includes(targetAddress)) return true;
  return String(safeValue(() => message.allHeaders(), ""))
    .toLowerCase()
    .includes(targetAddress);
}

function resolveAccount(Mail, targetAddress) {
  return Mail.accounts().find((candidate) => {
    const addresses = safeValue(() => candidate.emailAddresses(), []);
    const enabled = Boolean(safeValue(() => candidate.enabled(), false));
    return enabled && addresses.map((value) => String(value).toLowerCase()).includes(targetAddress);
  });
}

function selectedMailboxes(account, config, requested) {
  let configured = (config.emailMailboxes || ["INBOX", "Junk", "Archive", "Deleted Messages"])
    .map((value) => String(value).toLowerCase());
  if (requested && requested.length) {
    const wanted = requested.map((value) => String(value).toLowerCase());
    const unknown = wanted.filter((value) => !configured.includes(value));
    if (unknown.length) throw new Error(`Mailbox is not configured for read access: ${unknown.join(", ")}`);
    configured = wanted;
  }
  const result = [];
  for (const mailbox of safeValue(() => account.mailboxes(), [])) {
    const name = String(safeValue(() => mailbox.name(), "Unknown"));
    if (configured.includes(name.toLowerCase())) result.push({name, mailbox});
  }
  if (!result.length) throw new Error("None of the configured Apple Mail mailboxes were found");
  return result;
}

function mailboxIndex(entry) {
  const messages = entry.mailbox.messages;
  return {
    entry,
    messages,
    ids: safeValue(() => messages.id(), []),
    messageIds: safeValue(() => messages.messageId(), []),
    dates: safeValue(() => messages.dateReceived(), []),
    senders: safeValue(() => messages.sender(), []),
    subjects: safeValue(() => messages.subject(), []),
    readStatuses: safeValue(() => messages.readStatus(), []),
    flaggedStatuses: safeValue(() => messages.flaggedStatus(), [])
  };
}

function metadataAt(index, position) {
  const localId = String(index.ids[position] || "");
  const rawMessageId = String(index.messageIds[position] || "");
  const messageId = normalizedMessageId(rawMessageId);
  const received = index.dates[position] || null;
  return {
    id: `mail:${localId}`,
    sourceKey: `email:${messageId || `local:${localId}`}`,
    messageId,
    mailbox: index.entry.name,
    sender: cleanText(index.senders[position] || "unknown", 300),
    senderAddress: "",
    subject: cleanText(index.subjects[position] || "(no subject)", 500),
    receivedAt: received && received.toISOString ? received.toISOString() : String(received || ""),
    read: Boolean(index.readStatuses[position]),
    flagged: Boolean(index.flaggedStatuses[position]),
    url: messageURL(messageId)
  };
}

function bodyAt(index, position) {
  return cleanText(
    safeValue(() => index.messages[position].content(), ""),
    MAX_BODY_CHARACTERS
  );
}

function status(config, request, account) {
  const mailboxes = selectedMailboxes(account, config, request.mailboxes);
  const counts = {};
  for (const entry of mailboxes) {
    counts[entry.name] = safeValue(() => entry.mailbox.messages.id(), []).length;
  }
  return {
    status: "ok",
    verified: true,
    operation: "status",
    connector: CONNECTOR,
    account: config.emailAddress,
    retrievedAt: isoNow(),
    mailboxes: counts
  };
}

function snippet(text, query, limit) {
  const compact = String(text || "").replace(/\s+/g, " ").trim();
  if (compact.length <= limit) return compact;
  const position = query ? compact.toLowerCase().indexOf(query.toLowerCase()) : -1;
  const start = position >= 0 ? Math.max(0, position - Math.floor(limit / 3)) : 0;
  const end = Math.min(compact.length, start + limit);
  return `${start ? "…" : ""}${compact.slice(start, end)}${end < compact.length ? "…" : ""}`;
}

function search(config, request, account) {
  const query = String(request.query || "").trim();
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean);
  const days = Math.min(Math.max(Number(request.days || 30), 1), 3650);
  const limit = Math.min(Math.max(Number(request.limit || 10), 1), 50);
  const cutoff = new Date(Date.now() - days * 24 * 60 * 60 * 1000);
  const mailboxes = selectedMailboxes(account, config, request.mailboxes);
  const candidates = [];
  let scanned = 0;
  let bodyScanned = 0;
  let scanTruncated = false;
  for (const entry of mailboxes) {
    const index = mailboxIndex(entry);
    for (let position = 0; position < index.ids.length; position += 1) {
      const received = index.dates[position];
      if (received && received < cutoff) break;
      if (scanned >= MAX_SEARCH_CANDIDATES) {
        scanTruncated = true;
        break;
      }
      scanned += 1;
      const item = metadataAt(index, position);
      const metadataText = [item.sender, item.subject].join("\n").toLowerCase();
      let body = "";
      let matches = !terms.length || terms.every((term) => metadataText.includes(term));
      if (!matches && bodyScanned < MAX_BODY_SEARCH_CANDIDATES) {
        bodyScanned += 1;
        body = bodyAt(index, position);
        const combined = `${metadataText}\n${body.toLowerCase()}`;
        matches = terms.every((term) => combined.includes(term));
      }
      if (!matches) continue;
      if (!body) body = bodyAt(index, position);
      candidates.push({...item, snippet: snippet(body, query, 700), attachments: []});
      if (!query && candidates.length >= limit * mailboxes.length) break;
    }
  }
  candidates.sort((left, right) => String(right.receivedAt).localeCompare(String(left.receivedAt)));
  return {
    status: "ok",
    verified: true,
    operation: "search",
    connector: CONNECTOR,
    account: config.emailAddress,
    mailboxes: mailboxes.map((entry) => entry.name),
    query,
    days,
    retrievedAt: isoNow(),
    resultCount: Math.min(candidates.length, limit),
    candidateCount: scanned,
    bodyCandidateCount: bodyScanned,
    truncated: candidates.length > limit || scanTruncated || bodyScanned >= MAX_BODY_SEARCH_CANDIDATES,
    results: candidates.slice(0, limit)
  };
}

function readMessage(config, request, account) {
  let identifier = decodeURIComponent(String(request.identifier || "").trim());
  if (identifier.startsWith("email:")) identifier = identifier.slice(6);
  if (!identifier) throw new Error("A message identifier is required");
  const wantedLocalId = identifier.startsWith("mail:") ? identifier.slice(5) : "";
  const wantedMessageId = normalizedMessageId(identifier);
  const mailboxes = selectedMailboxes(account, config, request.mailboxes);
  for (const entry of mailboxes) {
    const index = mailboxIndex(entry);
    for (let position = 0; position < index.ids.length; position += 1) {
      const item = metadataAt(index, position);
      if (
        (wantedLocalId && item.id === `mail:${wantedLocalId}`) ||
        identifier === item.sourceKey ||
        (wantedMessageId && wantedMessageId === item.messageId)
      ) {
        const body = bodyAt(index, position);
        return {
          status: "ok",
          verified: true,
          operation: "read",
          connector: CONNECTOR,
          account: config.emailAddress,
          retrievedAt: isoNow(),
          message: {...item, body, attachments: []}
        };
      }
    }
  }
  return {
    status: "not-found",
    verified: true,
    operation: "read",
    connector: CONNECTOR,
    account: config.emailAddress,
    identifier,
    retrievedAt: isoNow()
  };
}

function run() {
  const request = readJSON(REQUEST_PATH);
  let config = {};
  let response;
  try {
    config = readJSON(CONFIG_PATH);
    const Mail = Application("Mail");
    const target = String(config.emailAddress || "").toLowerCase();
    const account = resolveAccount(Mail, target);
    if (!account) throw new Error(`No enabled Apple Mail account contains ${target}`);
    if (request.operation === "status") response = status(config, request, account);
    else if (request.operation === "search") response = search(config, request, account);
    else if (request.operation === "read") response = readMessage(config, request, account);
    else throw new Error(`Unsupported mail operation: ${request.operation}`);
  } catch (error) {
    response = {
      status: "error",
      verified: false,
      operation: String(request.operation || "unknown"),
      connector: CONNECTOR,
      account: String(config.emailAddress || "unknown"),
      retrievedAt: isoNow(),
      error: String(error).slice(0, 800)
    };
  }
  response.nonce = String(request.nonce || "");
  writePrivateJSON(RESPONSE_PATH, response);
  return JSON.stringify({status: response.status, operation: response.operation});
}
