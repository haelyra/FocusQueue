ObjC.import("Foundation");

// launchd starts the reader without a shell, so derive paths from the home folder.
const SUPPORT_PATH = ObjC.unwrap($.NSHomeDirectory()) + "/Library/Application Support/ECC Focus Queue";
const CONFIG_PATH = SUPPORT_PATH + "/ingestion.json";
const DEFAULT_REQUEST_PATH = SUPPORT_PATH + "/connector-commands";
const DEFAULT_RESPONSE_PATH = SUPPORT_PATH + "/mail-proofs";
const GMAIL_CONNECTOR_PATH = SUPPORT_PATH + "/automation/Scripts/focus_queue_gmail.py";
const CONNECTOR = "ecc-focus-mail-reader";
const MAX_BODY_CHARACTERS = 100000;
const MAX_SEARCH_CANDIDATES = 5000;
const MAX_BODY_SEARCH_CANDIDATES = 250;
// Bodies that Mail has not cached locally download from the server one by
// one. Stop body matching well inside the client's 90-second timeout.
const BODY_SEARCH_BUDGET_MS = 45000;
const MAX_DAILY_REPORT_RESULTS = 500;
const MAX_EMPTY_QUERY_BODY_SNIPPETS = 25;
const METADATA_PROPERTIES = ["messageId", "dateReceived", "sender", "subject", "readStatus", "flaggedStatus"];
const RECIPIENT_PROPERTIES = ["toRecipients", "ccRecipients", "bccRecipients"];
const SNAPSHOT_ATTEMPTS = 3;

function safeValue(operation, fallback) {
  try {
    const value = operation();
    return value === undefined || value === null ? fallback : value;
  } catch (error) {
    // Optional message fields can be missing. Authorization and transport
    // failures must reach the response, rather than look like empty mailboxes.
    if (["mail_permission_required", "mail_reader_timeout"].includes(errorCode(error))) throw error;
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

function errorCode(error) {
  const detail = String(error || "").toLowerCase();
  if (Number(error && error.number) === -1743 || detail.includes("not authorized to send apple events") || detail.includes("-1743")) {
    return "mail_permission_required";
  }
  if (Number(error && error.number) === -1712 || detail.includes("-1712") || detail.includes("appleevent timed out")) {
    return "mail_reader_timeout";
  }
  if (detail.includes("mailbox is not configured")) return "mailbox_not_configured";
  if (detail.includes("no enabled apple mail account")) return "mail_account_unavailable";
  if (detail.includes("mailboxes were found")) return "mailbox_unavailable";
  if (detail.includes("permission") || detail.includes("operation not permitted")) return "mail_runtime_permission_required";
  return "mail_reader_failed";
}

function recoveryHint(code) {
  if (code === "mail_permission_required") {
    return "Allow ECC Focus Mail Reader > Mail in System Settings > Privacy & Security > Automation. " +
      "The signed helper uses tools.ecc.focus-mail-reader; older applet and python entries are separate identities. " +
      "If the helper is already enabled, run the connector status check and inspect its current error before changing permissions.";
  }
  if (code === "mailbox_not_configured") return "Choose a configured mailbox or add the intended mailbox to emailMailboxes in ingestion settings, then retry.";
  if (code === "mail_runtime_permission_required") return "The helper could not access a local resource. Inspect the error and runtime paths; this is separate from Mail Automation approval.";
  if (code === "mail_reader_timeout") return "Apple Mail did not respond in time. Retry the connector status check after Mail finishes synchronizing.";
  return "Review the connector error and ingestion settings, then retry.";
}

function mailIPCPaths(config) {
  const requestRuntime = String(config.mailRequestDirectory || DEFAULT_REQUEST_PATH).replace(/\/+$/, "");
  const responseRuntime = String(config.mailResponseDirectory || DEFAULT_RESPONSE_PATH).replace(/\/+$/, "");
  return {
    request: `${requestRuntime}/mail-request.json`,
    response: `${responseRuntime}/mail-response.json`
  };
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

function configuredRecipients(config) {
  const configured = Array.isArray(config.emailAddresses) && config.emailAddresses.length
    ? config.emailAddresses
    : [config.emailAddress];
  return new Set(
    configured
      .map((value) => String(value || "").trim().toLowerCase())
      .filter(Boolean)
  );
}

function addressedTo(index, position, wanted) {
  for (const property of RECIPIENT_PROPERTIES) {
    for (const address of index.recipients[property][position] || []) {
      if (wanted.has(String(address).toLowerCase())) return true;
    }
  }
  return false;
}

function resolveAccount(Mail, targetAddress) {
  return Mail.accounts().find((candidate) => {
    const addresses = safeValue(() => candidate.emailAddresses(), []);
    const enabled = Boolean(safeValue(() => candidate.enabled(), false));
    return enabled && addresses.map((value) => String(value).toLowerCase()).includes(targetAddress);
  });
}

function selectedMailboxes(account, config, requested) {
  let configured = (config.emailMailboxes || ["INBOX"])
    .map((value) => String(value).toLowerCase());
  if (requested && requested.length) {
    const wanted = requested.map((value) => String(value).toLowerCase());
    const unknown = wanted.filter((value) => !configured.includes(value));
    if (unknown.length) throw new Error(`Mailbox is not configured for read access: ${unknown.join(", ")}. Configured mailboxes: ${configured.join(", ")}.`);
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

function sameValues(left, right) {
  if (left.length !== right.length) return false;
  for (let position = 0; position < left.length; position += 1) {
    if (String(left[position]) !== String(right[position])) return false;
  }
  return true;
}

function mailboxIndex(entry, options) {
  const includeRecipients = Boolean(options && options.recipients);
  const allMessages = entry.mailbox.messages;
  // Mail answers a property read on the whole mailbox collection with one
  // Apple Event: about 20-70 ms for 3,000 messages. The same read through a
  // range specifier (messages.slice) is evaluated message by message and costs
  // about 5 s per 1,000 messages, which pushed every daily-report page past
  // the 90-second reader timeout. Never read metadata through a range.
  const column = (operation) => Array.from(safeValue(operation, []));
  for (let attempt = 1; attempt <= SNAPSHOT_ATTEMPTS; attempt += 1) {
    const ids = column(() => allMessages.id());
    const metadata = {};
    for (const property of METADATA_PROPERTIES) {
      metadata[property] = column(() => allMessages[property]());
    }
    const recipients = {};
    if (includeRecipients) {
      // Recipients decide which messages are reported, so a failed read must
      // surface as an error instead of filtering every message away.
      for (const property of RECIPIENT_PROPERTIES) {
        recipients[property] = Array.from(allMessages[property].address());
      }
    }
    // Each column is a separate Apple Event. New mail shifts positions, so the
    // columns only describe the same messages when the ID list is unchanged.
    const settledIds = column(() => allMessages.id());
    const aligned = (values) => values.length === ids.length || values.length === 0;
    const recipientsAligned = Object.values(recipients).every(
      (values) => values.length === ids.length
    );
    if (
      sameValues(ids, settledIds) &&
      Object.values(metadata).every(aligned) &&
      recipientsAligned
    ) {
      return {
        entry,
        allMessages,
        ids,
        messageIds: metadata.messageId,
        dates: metadata.dateReceived,
        senders: metadata.sender,
        subjects: metadata.subject,
        readStatuses: metadata.readStatus,
        flaggedStatuses: metadata.flaggedStatus,
        recipients
      };
    }
  }
  throw new Error(
    `Mailbox ${entry.name} kept changing while its metadata was read; retry after Mail finishes synchronizing.`
  );
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
  // Address the body by Mail's stable message ID. Positions shift when new
  // mail arrives, and a range read would fetch every body between candidates.
  return cleanText(
    safeValue(() => index.allMessages.byId(index.ids[position]).content(), ""),
    MAX_BODY_CHARACTERS
  );
}

function pageBodies(candidates) {
  const bodyCandidates = candidates.slice(0, MAX_EMPTY_QUERY_BODY_SNIPPETS);
  const bodies = candidates.map(() => "");
  bodyCandidates.forEach((candidate, position) => {
    bodies[position] = candidate.body || bodyAt(candidate.index, candidate.position);
  });
  return {
    bodies,
    bodyResultCount: bodyCandidates.length,
    bodyTruncated: bodyCandidates.length < candidates.length
  };
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
  const limitCap = request.dailyReport ? MAX_DAILY_REPORT_RESULTS : 50;
  const limit = Math.min(Math.max(Number(request.limit || 10), 1), limitCap);
  const offset = Math.min(Math.max(Number(request.offset || 0), 0), MAX_SEARCH_CANDIDATES);
  const cutoff = new Date(Date.now() - days * 24 * 60 * 60 * 1000);
  const mailboxes = selectedMailboxes(account, config, request.mailboxes);
  // Match the Envelope Index reader: only mail addressed to a configured
  // address is in scope, whichever reader path the daily report takes.
  const recipients = configuredRecipients(config);
  const candidates = [];
  let scanned = 0;
  let bodyScanned = 0;
  let otherRecipientCount = 0;
  let duplicateCount = 0;
  const seenMessageIds = new Set();
  let scanTruncated = false;
  let bodyBudgetExhausted = false;
  const bodySearchDeadline = Date.now() + BODY_SEARCH_BUDGET_MS;
  for (const entry of mailboxes) {
    const index = mailboxIndex(entry, {recipients: recipients.size > 0});
    for (let position = 0; position < index.ids.length; position += 1) {
      const received = index.dates[position];
      // Mailbox order is not guaranteed. Query-less daily-report scans skip old
      // entries instead of stopping, so a full window is always covered.
      if (received && received < cutoff) {
        if (query) break;
        continue;
      }
      if (recipients.size && !addressedTo(index, position, recipients)) {
        otherRecipientCount += 1;
        continue;
      }
      if (scanned >= MAX_SEARCH_CANDIDATES) {
        scanTruncated = true;
        break;
      }
      const item = metadataAt(index, position);
      // Mail keeps one copy per delivery, so mail sent to two configured
      // aliases appears twice with one Message-ID. Report it once.
      if (item.messageId && seenMessageIds.has(item.messageId)) {
        duplicateCount += 1;
        continue;
      }
      if (item.messageId) seenMessageIds.add(item.messageId);
      scanned += 1;
      const metadataText = [item.sender, item.subject].join("\n").toLowerCase();
      let body = "";
      let matches = !terms.length || terms.every((term) => metadataText.includes(term));
      if (!matches && bodyScanned < MAX_BODY_SEARCH_CANDIDATES && Date.now() >= bodySearchDeadline) {
        bodyBudgetExhausted = true;
      }
      if (!matches && bodyScanned < MAX_BODY_SEARCH_CANDIDATES && !bodyBudgetExhausted) {
        bodyScanned += 1;
        body = bodyAt(index, position);
        const combined = `${metadataText}\n${body.toLowerCase()}`;
        matches = terms.every((term) => combined.includes(term));
      }
      if (!matches) continue;
      // Keep metadata candidates cheap. Fetch snippets only for the returned
      // page, rather than rereading every earlier page and every mailbox match.
      candidates.push({item, index, position, body});
    }
  }
  candidates.sort((left, right) => String(right.item.receivedAt).localeCompare(String(left.item.receivedAt)));
  const pageEnd = offset + limit;
  const pageCandidates = candidates.slice(offset, pageEnd);
  const bodyCoverage = query
    ? {bodies: [], bodyResultCount: pageCandidates.length, bodyTruncated: false}
    : pageBodies(pageCandidates);
  const results = pageCandidates.map((candidate, pagePosition) => {
    const body = query
      ? (candidate.body || bodyAt(candidate.index, candidate.position))
      : bodyCoverage.bodies[pagePosition];
    return {...candidate.item, snippet: snippet(body, query, 700), attachments: []};
  });
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
    resultCount: Math.max(0, Math.min(candidates.length, pageEnd) - offset),
    offset,
    candidateCount: scanned,
    recipientAddresses: Array.from(recipients),
    otherRecipientCount,
    duplicateCount,
    bodyCandidateCount: bodyScanned,
    bodyResultCount: bodyCoverage.bodyResultCount,
    bodyTruncated: bodyCoverage.bodyTruncated,
    truncated: candidates.length > pageEnd,
    hardTruncated: scanTruncated || bodyBudgetExhausted ||
      bodyScanned >= MAX_BODY_SEARCH_CANDIDATES || bodyCoverage.bodyTruncated,
    results
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

function requestIsCurrent(paths, nonce) {
  try {
    return String(readJSON(paths.request).nonce || "") === nonce;
  } catch (error) {
    return true;
  }
}

function run() {
  let config = {};
  let request = {};
  let paths = mailIPCPaths(config);
  let response;
  try {
    config = readJSON(CONFIG_PATH);
    paths = mailIPCPaths(config);
    request = readJSON(paths.request);
    if (String(config.emailProvider || "apple_mail").toLowerCase() === "gmail") {
      const app = Application.currentApplication();
      app.includeStandardAdditions = true;
      app.doShellScript(
        `/usr/bin/python3 ${shellQuote(GMAIL_CONNECTOR_PATH)} --config ${shellQuote(CONFIG_PATH)} serve`
      );
      response = readJSON(paths.response);
      if (String(response.nonce || "") !== String(request.nonce || "")) {
        throw new Error("Gmail connector returned a mismatched request nonce");
      }
      return JSON.stringify({status: response.status, operation: response.operation});
    }
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
      errorCode: errorCode(error),
      recoveryHint: recoveryHint(errorCode(error)),
      helperBundleIdentifier: "tools.ecc.focus-mail-reader",
      error: String(error).slice(0, 800)
    };
  }
  response.nonce = String(request.nonce || "");
  // launchd can start a second copy for the same request (WatchPaths plus an
  // explicit kickstart). A copy that finishes after a newer request arrived
  // must not overwrite that request's response.
  if (!requestIsCurrent(paths, response.nonce)) {
    return JSON.stringify({status: "superseded", operation: response.operation});
  }
  writePrivateJSON(paths.response, response);
  return JSON.stringify({status: response.status, operation: response.operation});
}
