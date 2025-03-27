/**
 * Import function triggers from their respective submodules:
 *
 * import {onCall} from "firebase-functions/v2/https";
 * import {onDocumentWritten} from "firebase-functions/v2/firestore";
 *
 * See a full list of supported triggers at https://firebase.google.com/docs/functions
 */

import * as functions from "firebase-functions";
import * as admin from "firebase-admin";
import {GoogleGenerativeAI} from "@google/generative-ai";

// Type definitions
interface ChatMessage {
    role: "user" | "assistant";
    content: string;
    timestamp: admin.firestore.FieldValue;
}

interface ChatData {
    message: string;
    conversationId?: string;
}

// Initialize Firebase Admin
admin.initializeApp();

// Initialize Gemini AI
const genAI = new GoogleGenerativeAI(process.env.GEMINI_API_KEY || "");

// Debug log
console.log("🚀 Cloud Functions initialized");

// Initialize services
const model = genAI.getGenerativeModel({model: "gemini-pro"});

// Chat History Function
export const getChatHistory = functions.https.onRequest(async (req, res) => {
  try {
    // Debug log
    console.log("📱 Fetching chat history...");

    // Check authentication
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      res.status(401).json({error: "Unauthorized"});
      return;
    }

    const idToken = authHeader.split("Bearer ")[1];
    const decodedToken = await admin.auth().verifyIdToken(idToken);
    const uid = decodedToken.uid;

    const snapshot = await admin.firestore()
      .collection("users")
      .doc(uid)
      .collection("conversations")
      .orderBy("timestamp", "desc")
      .limit(50)
      .get();

    const conversations = snapshot.docs.map((doc) => ({
      id: doc.id,
      ...doc.data(),
    }));

    // Debug log
    console.log("📱 Chat history fetched successfully:", {
      userId: uid,
      conversationCount: conversations.length,
    });

    res.json(conversations);
  } catch (error) {
    console.error("❌ Error fetching chat history:", error);
    res.status(500).json({error: "Failed to fetch chat history"});
  }
});

// Chat Message Function
export const processChatMessage = functions.https.onRequest(async (req, res) => {
  try {
    // Debug log
    console.log("💬 Processing chat message...");

    // Check authentication
    const authHeader = req.headers.authorization;
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      res.status(401).json({error: "Unauthorized"});
      return;
    }

    const idToken = authHeader.split("Bearer ")[1];
    const decodedToken = await admin.auth().verifyIdToken(idToken);
    const uid = decodedToken.uid;

    // Validate message
    const {message, conversationId} = req.body as ChatData;
    if (!message) {
      res.status(400).json({error: "Message is required"});
      return;
    }

    // Debug log
    console.log("💬 Processing request:", {
      userId: uid,
      messageLength: message.length,
      conversationId: conversationId || "new",
    });

    // Get or create conversation
    const conversationRef = conversationId ?
      admin.firestore()
        .collection("users")
        .doc(uid)
        .collection("conversations")
        .doc(conversationId) :
      admin.firestore()
        .collection("users")
        .doc(uid)
        .collection("conversations")
        .doc();

    // Get conversation history
    const conversationDoc = await conversationRef.get();
    const conversationData = conversationDoc.data() || {messages: []};

    // Add user message
    const userMessage: ChatMessage = {
      role: "user",
      content: message,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
    };

    // Generate response using Gemini
    const result = await model.generateContent(message);
    const response = result.response.text();

    // Add assistant message
    const assistantMessage: ChatMessage = {
      role: "assistant",
      content: response,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
    };

    // Update conversation
    await conversationRef.set({
      messages: [...conversationData.messages, userMessage, assistantMessage],
      lastUpdated: admin.firestore.FieldValue.serverTimestamp(),
    }, {merge: true});

    // Update user's message count
    await admin.firestore()
      .collection("users")
      .doc(uid)
      .update({
        messageCount: admin.firestore.FieldValue.increment(1),
      });

    // Debug log
    console.log("💬 Message processed successfully");

    res.json({
      role: "assistant",
      message: response,
      response: response,
      conversationId: conversationRef.id,
    });
  } catch (error) {
    console.error("❌ Error processing message:", error);
    res.status(500).json({error: "Failed to process message"});
  }
});
