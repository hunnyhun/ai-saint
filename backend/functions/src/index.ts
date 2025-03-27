import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';
import { GoogleGenerativeAI } from '@google/generative-ai';

// Initialize Firebase Admin
admin.initializeApp();

// Initialize Gemini AI
const genAI = new GoogleGenerativeAI(process.env.GEMINI_API_KEY || '');

// Debug log
console.log('🚀 Cloud Functions initialized');

// Initialize services
const model = genAI.getGenerativeModel({ model: 'gemini-pro' });

// Chat History Function
export const getChatHistory = functions.https.onCall(async (data, context) => {
    try {
        // Debug log
        console.log('📱 Fetching chat history...');
        
        // Check authentication
        if (!context.auth) {
            throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
        }
        
        const uid = context.auth.uid;
        const snapshot = await admin.firestore()
            .collection('users')
            .doc(uid)
            .collection('conversations')
            .orderBy('timestamp', 'desc')
            .limit(50)
            .get();
        
        const conversations = snapshot.docs.map(doc => ({
            id: doc.id,
            ...doc.data()
        }));
        
        // Debug log
        console.log('📱 Chat history fetched successfully:', {
            userId: uid,
            conversationCount: conversations.length
        });
        
        return conversations;
    } catch (error) {
        console.error('❌ Error fetching chat history:', error);
        throw new functions.https.HttpsError('internal', 'Failed to fetch chat history');
    }
});

// Chat Message Function
export const processChatMessage = functions.https.onCall(async (data, context) => {
    try {
        // Debug log
        console.log('💬 Processing chat message...');
        
        // Check authentication
        if (!context.auth) {
            throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
        }
        
        // Validate message
        if (!data.message) {
            throw new functions.https.HttpsError('invalid-argument', 'Message is required');
        }
        
        const { message, conversationId } = data;
        const uid = context.auth.uid;
        
        // Debug log
        console.log('💬 Processing request:', {
            userId: uid,
            messageLength: message.length,
            conversationId: conversationId || 'new'
        });
        
        // Get or create conversation
        const conversationRef = conversationId
            ? admin.firestore()
                .collection('users')
                .doc(uid)
                .collection('conversations')
                .doc(conversationId)
            : admin.firestore()
                .collection('users')
                .doc(uid)
                .collection('conversations')
                .doc();
        
        // Get conversation history
        const conversationDoc = await conversationRef.get();
        const conversationData = conversationDoc.data() || { messages: [] };
        
        // Add user message
        const userMessage = {
            role: 'user',
            content: message,
            timestamp: admin.firestore.FieldValue.serverTimestamp()
        };
        
        // Generate response using Gemini
        const result = await model.generateContent(message);
        const response = result.response.text();
        
        // Add assistant message
        const assistantMessage = {
            role: 'assistant',
            content: response,
            timestamp: admin.firestore.FieldValue.serverTimestamp()
        };
        
        // Update conversation
        await conversationRef.set({
            messages: [...conversationData.messages, userMessage, assistantMessage],
            lastUpdated: admin.firestore.FieldValue.serverTimestamp()
        }, { merge: true });
        
        // Update user's message count
        await admin.firestore()
            .collection('users')
            .doc(uid)
            .update({
                messageCount: admin.firestore.FieldValue.increment(1)
            });
        
        // Debug log
        console.log('💬 Message processed successfully');
        
        return {
            role: 'assistant',
            message: response,
            response: response,
            conversationId: conversationRef.id
        };
    } catch (error) {
        console.error('❌ Error processing message:', error);
        throw new functions.https.HttpsError('internal', 'Failed to process message');
    }
}); 