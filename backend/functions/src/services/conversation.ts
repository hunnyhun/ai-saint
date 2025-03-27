import * as admin from 'firebase-admin';
import { GoogleGenerativeAI } from '@google/generative-ai';

// Initialize Gemini AI
const genAI = new GoogleGenerativeAI(process.env.GEMINI_API_KEY || '');

// Debug log
console.log('💬 Conversation service initialized');

export class ConversationService {
    private model = genAI.getGenerativeModel({ model: 'gemini-pro' });
    
    async getConversationHistory(uid: string) {
        try {
            // Debug log
            console.log('📱 Fetching conversation history for user:', uid);
            
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
            console.log('📱 Found conversations:', conversations.length);
            
            return conversations;
        } catch (error) {
            console.error('❌ Error fetching conversation history:', error);
            throw error;
        }
    }
    
    async processMessage(message: string, uid: string, conversationId?: string) {
        try {
            // Debug log
            console.log('💬 Processing message:', {
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
            const prompt = this.buildPrompt(conversationData.messages, message);
            const result = await this.model.generateContent(prompt);
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
                message: response,
                conversationId: conversationRef.id
            };
        } catch (error) {
            console.error('❌ Error processing message:', error);
            throw error;
        }
    }
    
    private buildPrompt(messages: any[], currentMessage: string): string {
        const context = messages
            .slice(-5) // Get last 5 messages for context
            .map(msg => `${msg.role}: ${msg.content}`)
            .join('\n');
        
        return `Previous conversation:
${context}

User: ${currentMessage}

Assistant:`;
    }
} 