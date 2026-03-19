const test = require("node:test");
const assert = require("node:assert/strict");
const { randomUUID } = require("node:crypto");

const { initializeApp, getApps, deleteApp } = require("firebase-admin/app");
const { getFirestore, Timestamp } = require("firebase-admin/firestore");

const {
  persistTokensAfterCodeExchange,
  getValidCalendarAccessToken,
  disconnectCalendar,
} = require("../google_calendar");

const PROJECT_ID = process.env.GCLOUD_PROJECT || "demo-ai-mic";

function requireFirestoreEmulator() {
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    throw new Error(
      "FIRESTORE_EMULATOR_HOST is not set. Run with Firebase Firestore emulator."
    );
  }
}

function privateRef(db, uid) {
  return db.collection("users").doc(uid).collection("private").doc("google_calendar");
}

function integrationRef(db, uid) {
  return db.collection("users").doc(uid).collection("integrations").doc("calendar");
}

async function seedCalendarMockData(db, uid, overrides = {}) {
  const now = new Date();
  const inOneHour = new Date(now.getTime() + 60 * 60 * 1000);

  const privateData = {
    refreshToken: "mock_refresh_token",
    accessToken: "mock_access_token",
    accessTokenExpiresAt: Timestamp.fromDate(inOneHour),
    scope: "https://www.googleapis.com/auth/calendar",
    calendarEmail: "mock@example.com",
    updatedAt: Timestamp.now(),
    ...(overrides.privateData || {}),
  };

  const integrationData = {
    connected: true,
    calendarEmail: "mock@example.com",
    updatedAt: Timestamp.now(),
    ...(overrides.integrationData || {}),
  };

  await privateRef(db, uid).set(privateData);
  await integrationRef(db, uid).set(integrationData);

  return { privateData, integrationData };
}

test("calendar integration: seed mock data at correct paths and format", async () => {
  requireFirestoreEmulator();
  if (!getApps().length) {
    initializeApp({ projectId: PROJECT_ID });
  }
  const db = getFirestore();
  const uid = `it-${randomUUID()}`;

  const seeded = await seedCalendarMockData(db, uid);

  const privateSnap = await privateRef(db, uid).get();
  const integrationSnap = await integrationRef(db, uid).get();

  assert.equal(privateSnap.exists, true);
  assert.equal(integrationSnap.exists, true);

  const p = privateSnap.data();
  const i = integrationSnap.data();

  assert.equal(typeof p.refreshToken, "string");
  assert.equal(typeof p.accessToken, "string");
  assert.equal(p.accessTokenExpiresAt instanceof Timestamp, true);
  assert.equal(typeof p.scope, "string");
  assert.equal(typeof i.connected, "boolean");
  assert.equal(typeof i.calendarEmail, "string");
  assert.deepEqual(p.scope, seeded.privateData.scope);
});

test("calendar integration: persistTokensAfterCodeExchange creates connected state", async () => {
  requireFirestoreEmulator();
  if (!getApps().length) {
    initializeApp({ projectId: PROJECT_ID });
  }
  const db = getFirestore();
  const uid = `it-${randomUUID()}`;

  const result = await persistTokensAfterCodeExchange(uid, {
    refresh_token: "fresh_refresh_token",
    scope: "https://www.googleapis.com/auth/calendar",
  });

  assert.equal(result.connected, true);

  const privateSnap = await privateRef(db, uid).get();
  const integrationSnap = await integrationRef(db, uid).get();
  assert.equal(privateSnap.exists, true);
  assert.equal(integrationSnap.exists, true);
  assert.equal(privateSnap.data().refreshToken, "fresh_refresh_token");
  assert.equal(integrationSnap.data().connected, true);
});

test("calendar integration: getValidCalendarAccessToken reads existing valid token", async () => {
  requireFirestoreEmulator();
  if (!getApps().length) {
    initializeApp({ projectId: PROJECT_ID });
  }
  const db = getFirestore();
  const uid = `it-${randomUUID()}`;
  const inTwoHours = new Date(Date.now() + 2 * 60 * 60 * 1000);

  await seedCalendarMockData(db, uid, {
    privateData: {
      refreshToken: "mock_refresh_token",
      accessToken: "already_valid_access_token",
      accessTokenExpiresAt: Timestamp.fromDate(inTwoHours),
    },
  });

  const token = await getValidCalendarAccessToken(uid, {
    clientId: "mock-client-id.apps.googleusercontent.com",
    clientSecret: "mock-client-secret",
  });

  assert.equal(token.accessToken, "already_valid_access_token");
  assert.equal(
    token.scope,
    "https://www.googleapis.com/auth/calendar"
  );
});

test("calendar integration: disconnectCalendar removes private data and marks disconnected", async () => {
  requireFirestoreEmulator();
  if (!getApps().length) {
    initializeApp({ projectId: PROJECT_ID });
  }
  const db = getFirestore();
  const uid = `it-${randomUUID()}`;

  await seedCalendarMockData(db, uid);
  await disconnectCalendar(uid);

  const privateSnap = await privateRef(db, uid).get();
  const integrationSnap = await integrationRef(db, uid).get();

  assert.equal(privateSnap.exists, false);
  assert.equal(integrationSnap.exists, true);
  assert.equal(integrationSnap.data().connected, false);
  assert.equal(integrationSnap.data().calendarEmail, null);
});

test.after(async () => {
  const apps = getApps();
  await Promise.all(apps.map((app) => deleteApp(app)));
});
