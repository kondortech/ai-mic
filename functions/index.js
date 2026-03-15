const { onRequest } = require("firebase-functions/v2/https");

exports.helloWorld = onRequest(
  {
    // Use App Engine default SA; avoids missing Compute Engine default SA.
    serviceAccount: "ai-mic-18768@appspot.gserviceaccount.com",
  },
  (req, res) => {
    res.json({ message: "Hello from Firebase Cloud Functions" });
  }
);
