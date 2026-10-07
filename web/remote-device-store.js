// Browser-side custody for Noise device keys and relay bearer credentials.
// The AES key is a non-extractable CryptoKey stored by IndexedDB; credential
// records contain only AES-GCM ciphertext, never a reusable secret in a URL.
"use strict";

(() => {
  const DATABASE = "exosuit-remote-devices-v1";
  const VERSION = 1;
  const META = "meta";
  const DEVICES = "devices";
  const WRAPPING_KEY_ID = "noise-device-wrap-v1";
  const encoder = new TextEncoder();
  const decoder = new TextDecoder("utf-8", {fatal: true});
  let databasePromise = null;
  let wrappingKeyPromise = null;

  function validId(value) {
    return typeof value === "string" && /^[0-9a-f]{32}$/.test(value);
  }

  function recordId(machineId, deviceId) {
    if (!validId(machineId) || !validId(deviceId)) throw new TypeError("Invalid remote device identity");
    return `${machineId}:${deviceId}`;
  }

  function validRelayOrigin(value) {
    if (typeof value !== "string") return false;
    try {
      const url = new URL(value);
      if (url.origin !== value || url.username || url.password || url.pathname !== "/" || url.search || url.hash)
        return false;
      return url.protocol === "https:" || (url.protocol === "http:"
        && (url.hostname === "localhost" || url.hostname === "127.0.0.1"));
    } catch (_error) {
      return false;
    }
  }

  function openDatabase() {
    if (databasePromise) return databasePromise;
    databasePromise = new Promise((resolve, reject) => {
      if (!globalThis.indexedDB || !globalThis.crypto?.subtle)
        return reject(new Error("Secure browser storage is unavailable; use HTTPS or localhost"));
      const request = indexedDB.open(DATABASE, VERSION);
      request.onupgradeneeded = () => {
        const database = request.result;
        if (!database.objectStoreNames.contains(META)) database.createObjectStore(META, {keyPath: "id"});
        if (!database.objectStoreNames.contains(DEVICES)) database.createObjectStore(DEVICES, {keyPath: "id"});
      };
      request.onsuccess = () => {
        const database = request.result;
        database.onversionchange = () => {
          database.close();
          databasePromise = null;
          wrappingKeyPromise = null;
        };
        resolve(database);
      };
      request.onerror = () => reject(request.error || new Error("Could not open secure browser storage"));
      request.onblocked = () => reject(new Error("Close other exosuit tabs to update secure browser storage"));
    }).catch(error => {
      databasePromise = null;
      throw error;
    });
    return databasePromise;
  }

  function requestResult(request) {
    return new Promise((resolve, reject) => {
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error("Browser storage request failed"));
    });
  }

  function transactionDone(transaction, message) {
    return new Promise((resolve, reject) => {
      transaction.oncomplete = resolve;
      transaction.onerror = () => reject(transaction.error || new Error(message));
      transaction.onabort = () => reject(transaction.error || new Error(message));
    });
  }

  async function readWrappingKey(database) {
    const transaction = database.transaction(META, "readonly");
    const record = await requestResult(transaction.objectStore(META).get(WRAPPING_KEY_ID));
    return record?.key || null;
  }

  async function wrappingKey() {
    if (wrappingKeyPromise) return wrappingKeyPromise;
    wrappingKeyPromise = (async () => {
      const database = await openDatabase();
      const stored = await readWrappingKey(database);
      if (stored) return stored;
      const generated = await crypto.subtle.generateKey({name: "AES-GCM", length: 256}, false, ["encrypt", "decrypt"]);
      try {
        const transaction = database.transaction(META, "readwrite");
        const done = transactionDone(transaction, "Could not save browser wrapping key");
        transaction.objectStore(META).add({id: WRAPPING_KEY_ID, key: generated});
        await done;
        return generated;
      } catch (error) {
        const winner = await readWrappingKey(database);
        if (winner) return winner;
        throw error;
      }
    })().catch(error => {
      wrappingKeyPromise = null;
      throw error;
    });
    return wrappingKeyPromise;
  }

  function validateCredentials(credentials) {
    if (!credentials || typeof credentials !== "object"
      || typeof credentials.staticPrivateKey !== "string" || !/^[0-9a-f]{64}$/.test(credentials.staticPrivateKey)
      || typeof credentials.deviceToken !== "string" || !/^[0-9a-f]{64}$/.test(credentials.deviceToken)
      || typeof credentials.machineStaticPublicKey !== "string" || !/^[0-9a-f]{64}$/.test(credentials.machineStaticPublicKey)
      || credentials.relayOrigin !== undefined && credentials.relayOrigin !== null
        && !validRelayOrigin(credentials.relayOrigin))
      throw new TypeError("Invalid remote device credentials");
  }

  async function save(machineId, deviceId, credentials) {
    const id = recordId(machineId, deviceId);
    validateCredentials(credentials);
    const database = await openDatabase();
    const key = await wrappingKey();
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const plaintext = encoder.encode(JSON.stringify({version: 1, staticPrivateKey: credentials.staticPrivateKey,
      deviceToken: credentials.deviceToken, machineStaticPublicKey: credentials.machineStaticPublicKey,
      relayOrigin: credentials.relayOrigin || null}));
    const additionalData = encoder.encode(`${id}:v1`);
    let ciphertext;
    try {
      ciphertext = await crypto.subtle.encrypt({name: "AES-GCM", iv, additionalData, tagLength: 128}, key, plaintext);
    } finally {
      plaintext.fill(0);
    }
    const transaction = database.transaction(DEVICES, "readwrite");
    const done = transactionDone(transaction, "Could not save remote device credentials");
    transaction.objectStore(DEVICES).put({id, machineId, deviceId, version: 1,
      relayOrigin: credentials.relayOrigin || null, iv: iv.buffer, ciphertext, updatedAt: Date.now()});
    await done;
  }

  async function load(machineId, deviceId) {
    const id = recordId(machineId, deviceId);
    const database = await openDatabase();
    const transaction = database.transaction(DEVICES, "readonly");
    const record = await requestResult(transaction.objectStore(DEVICES).get(id));
    if (!record) return null;
    if (record.version !== 1 || !(record.iv instanceof ArrayBuffer) || !(record.ciphertext instanceof ArrayBuffer))
      throw new Error("Remote device credential record is invalid");
    const key = await wrappingKey();
    let plaintext;
    try {
      plaintext = await crypto.subtle.decrypt({name: "AES-GCM", iv: record.iv,
        additionalData: encoder.encode(`${id}:v1`), tagLength: 128}, key, record.ciphertext);
      const credentials = JSON.parse(decoder.decode(plaintext));
      validateCredentials(credentials);
      if (credentials.version !== 1) throw new Error("Unsupported remote device credential version");
      if (credentials.relayOrigin != null && !validRelayOrigin(credentials.relayOrigin))
        throw new Error("Invalid saved relay origin");
      return {staticPrivateKey: credentials.staticPrivateKey, deviceToken: credentials.deviceToken,
        machineStaticPublicKey: credentials.machineStaticPublicKey, relayOrigin: credentials.relayOrigin || null};
    } catch (_error) {
      throw new Error("Remote device credentials could not be authenticated");
    } finally {
      if (plaintext) new Uint8Array(plaintext).fill(0);
    }
  }

  async function list() {
    const database = await openDatabase();
    const transaction = database.transaction(DEVICES, "readonly");
    const records = await requestResult(transaction.objectStore(DEVICES).getAll());
    return records.map(record => ({machineId: record.machineId, deviceId: record.deviceId,
      relayOrigin: validRelayOrigin(record.relayOrigin) ? record.relayOrigin : null,
      updatedAt: record.updatedAt})).sort((left, right) => left.machineId.localeCompare(right.machineId)
        || left.deviceId.localeCompare(right.deviceId));
  }

  async function remove(machineId, deviceId) {
    const database = await openDatabase();
    const transaction = database.transaction(DEVICES, "readwrite");
    const done = transactionDone(transaction, "Could not remove remote device credentials");
    transaction.objectStore(DEVICES).delete(recordId(machineId, deviceId));
    await done;
  }

  async function clear() {
    const database = await openDatabase();
    const transaction = database.transaction([META, DEVICES], "readwrite");
    const done = transactionDone(transaction, "Could not clear remote device credentials");
    transaction.objectStore(META).clear();
    transaction.objectStore(DEVICES).clear();
    await done;
    wrappingKeyPromise = null;
  }

  Object.defineProperty(globalThis, "ExosuitRemoteDeviceStore", {value: Object.freeze({save, load, list, remove, clear}),
    configurable: false, enumerable: false, writable: false});
})();
