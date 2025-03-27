import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';
import { GoogleGenerativeAI } from '@google/generative-ai';

// Initialize Firebase Admin
admin.initializeApp();

// Initialize Gemini AI
const genAI = new GoogleGenerativeAI(process.env.GEMINI_API_KEY || '');

// Debug log
console.log('🔔 Cloud Functions initialized');

export const sendDailyQuotes = functions.pubsub
    .schedule('0 7,13,19,23 * * *') // Run at 07:00, 13:00, 19:00, and 23:00
    .timeZone('UTC')
    .onRun(async (context) => {
        try {
            // Get all users
            const usersSnapshot = await admin.firestore().collection('users').get();
            
            for (const userDoc of usersSnapshot.docs) {
                const userData = userDoc.data();
                const fcmToken = userData.fcmToken;
                
                if (!fcmToken) continue;
                
                // Get user's previous messages
                const messagesSnapshot = await userDoc.ref
                    .collection('messages')
                    .orderBy('timestamp', 'desc')
                    .limit(10)
                    .get();
                
                const messages = messagesSnapshot.docs.map(doc => doc.data().content);
                
                // Generate quote using Gemini
                const model = genAI.getGenerativeModel({ model: 'gemini-pro' });
                const prompt = `Based on these user messages: ${messages.join(', ')}. Generate an inspiring quote to help them.`;
                
                const result = await model.generateContent(prompt);
                const quote = result.response.text();
                
                // Send notification
                const message = {
                    notification: {
                        title: 'Daily Inspiration',
                        body: quote
                    },
                    token: fcmToken
                };
                
                await admin.messaging().send(message);
                
                // Debug log
                console.log(`🔔 Sent notification to user ${userDoc.id}`);
            }
            
            return null;
        } catch (error) {
            console.error('Error sending notifications:', error);
            throw error;
        }
    }); 