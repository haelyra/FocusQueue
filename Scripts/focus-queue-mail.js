ObjC.import("Foundation");

function safeValue(operation, fallback) {
  try {
    const value = operation();
    return value === undefined || value === null ? fallback : value;
  } catch (_) {
    return fallback;
  }
}

function cleanText(value, limit) {
  const normalized = String(value || "").replace(/\u0000/g, "").replace(/\s+/g, " ").trim();
  return normalized.length > limit ? `${normalized.slice(0, limit)}…` : normalized;
}

function readJSONFile(path) {
  const contents = $.NSString.stringWithContentsOfFileEncodingError(
    $(path).stringByStandardizingPath,
    $.NSUTF8StringEncoding,
    null
  );
  if (!contents) throw new Error(`Could not read ${path}`);
  return JSON.parse(ObjC.unwrap(contents));
}

function recipientAddresses(message) {
  const result = [];
  for (const property of ["toRecipients", "ccRecipients", "bccRecipients"]) {
    const recipients = safeValue(() => message[property](), []);
    for (const recipient of recipients) {
      const address = safeValue(() => recipient.address(), "");
      if (address) result.push(String(address).toLowerCase());
    }
  }
  return result;
}

function messageURL(messageId) {
  if (!messageId) return "";
  const bracketed = messageId.startsWith("<") ? messageId : `<${messageId}>`;
  return `message://${encodeURIComponent(bracketed)}`;
}

function collect(argv) {
  const targetAddress = String(argv[0] || "").toLowerCase();
  const lookbackHours = Math.max(1, Number(argv[1] || 168));
  const maximumMessages = Math.max(1, Number(argv[2] || 200));
  const requestedMailbox = String(argv[3] || "").toLowerCase();
  const cutoff = new Date(Date.now() - lookbackHours * 60 * 60 * 1000);
  const Mail = Application("Mail");
  const accounts = Mail.accounts();
  const account = accounts.find((candidate) => {
    const addresses = safeValue(() => candidate.emailAddresses(), []);
    const enabled = Boolean(safeValue(() => candidate.enabled(), false));
    return enabled && addresses.map((item) => String(item).toLowerCase()).includes(targetAddress);
  });

  if (!account) {
    return JSON.stringify({
      status: "unavailable",
      error: `No enabled Apple Mail account contains ${targetAddress}`,
      messages: []
    });
  }

  const excludedMailboxes = new Set([
    "drafts",
    "sent",
    "sent messages",
    "outbox",
    "notes"
  ]);
  const messages = [];
  const errors = [];
  let mailboxesScanned = 0;

  for (const mailbox of safeValue(() => account.mailboxes(), [])) {
    const mailboxName = String(safeValue(() => mailbox.name(), "Unknown"));
    if (excludedMailboxes.has(mailboxName.toLowerCase())) continue;
    if (requestedMailbox && mailboxName.toLowerCase() !== requestedMailbox) continue;
    mailboxesScanned += 1;

    let recent = [];
    try {
      recent = mailbox.messages.whose({ dateReceived: { _greaterThan: cutoff } })();
    } catch (error) {
      errors.push(`${mailboxName}: ${String(error).slice(0, 160)}`);
      continue;
    }

    for (const message of recent) {
      const recipients = recipientAddresses(message);
      const headers = String(safeValue(() => message.allHeaders(), "")).toLowerCase();
      if (!recipients.includes(targetAddress) && !headers.includes(targetAddress)) continue;

      const received = safeValue(() => message.dateReceived(), null);
      const rawMessageId = String(safeValue(() => message.messageId(), ""));
      const localId = String(safeValue(() => message.id(), ""));
      messages.push({
        sourceKey: `email:${rawMessageId || localId}`,
        messageId: rawMessageId,
        mailbox: mailboxName,
        sender: cleanText(safeValue(() => message.sender(), ""), 240),
        subject: cleanText(safeValue(() => message.subject(), "(no subject)"), 300),
        receivedAt: received && received.toISOString ? received.toISOString() : String(received || ""),
        read: Boolean(safeValue(() => message.readStatus(), false)),
        flagged: Boolean(safeValue(() => message.flaggedStatus(), false)),
        text: cleanText(safeValue(() => message.content(), ""), 1600),
        url: messageURL(rawMessageId)
      });
    }
  }

  messages.sort((left, right) => String(right.receivedAt).localeCompare(String(left.receivedAt)));
  return JSON.stringify({
    status: "ok",
    account: targetAddress,
    mailboxesScanned,
    messages: messages.slice(0, maximumMessages),
    truncated: messages.length > maximumMessages,
    errors
  });
}

function run(argv) {
  let effectiveArguments = argv;
  if (!effectiveArguments.length) {
    const home = ObjC.unwrap($.NSHomeDirectory());
    const applicationSupport = `${home}/Library/Application Support/ECC Focus Queue`;
    const config = readJSONFile(`${applicationSupport}/ingestion.json`);
    effectiveArguments = [
      String(config.emailAddress || ""),
      String(config.lookbackHours || 168),
      String(config.maxEmailMessages || 200),
      "",
      `${applicationSupport}/ingestion/mail-snapshot.json`
    ];
  }
  const result = collect(effectiveArguments);
  const outputPath = String(effectiveArguments[4] || "");
  if (outputPath) {
    const written = $(result).writeToFileAtomicallyEncodingError(
      $(outputPath).stringByStandardizingPath,
      true,
      $.NSUTF8StringEncoding,
      null
    );
    if (!written) throw new Error(`Could not write mail snapshot to ${outputPath}`);
  }
  return result;
}
