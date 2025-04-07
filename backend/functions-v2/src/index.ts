import { initializeApp } from 'firebase-admin/app';
import { getFirestore, FieldValue } from 'firebase-admin/firestore';
import { onCall } from 'firebase-functions/v2/https';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import { GoogleGenerativeAI } from '@google/generative-ai';
import { defineSecret } from 'firebase-functions/params';
import { getMessaging } from 'firebase-admin/messaging';

// Define the Gemini API key secret with a different name to avoid conflicts
const geminiSecretKey = defineSecret('GEMINI_SECRET_KEY');

// Rule: Always add debug logs
console.log('🚀 Cloud Functions V2 initialized');

// Initialize Firebase Admin with application default credentials
// This is safer than using a service account key file
const app = initializeApp();
console.log('🔥 Firebase Admin initialized', { appName: app.name });

// Get Firestore instance
const db = getFirestore();
console.log('📊 Firestore initialized');

// Get Messaging instance
const messaging = getMessaging();
console.log('📱 Firebase Messaging initialized');

// Define conversation data interface for type safety
interface ConversationData {
  messages: Array<{
    role: string;
    content: string;
    timestamp: any;
  }>;
  lastUpdated?: any;
}

// Check if user has premium subscription
async function checkUserSubscription(uid: string): Promise<boolean> {
    try {
        // Debug log
        console.log('💲 Checking subscription status for user:', uid);
        
        // First check RevenueCat customers collection
        const revenueCatCustomerRef = db.collection('customers').doc(uid);
        let revenueCatData;
        
        try {
            revenueCatData = await revenueCatCustomerRef.get();
        } catch (error) {
            console.log('💲 Error fetching RevenueCat data:', error);
            // Continue with fallback checks
        }
        
        if (revenueCatData && revenueCatData.exists) {
            const customerData = revenueCatData.data();
            console.log('💲 RevenueCat customer data found:', customerData);
            
            // Check if customer has active premium entitlement
            if (customerData?.subscriptions && 
                customerData.subscriptions['com.hunyhun.aisaint.premium.monthly']?.entitlements?.['Monthly Premium']?.active === true) {
                console.log('💲 User has active premium subscription via RevenueCat data');
                return true;
            }
        } else {
            console.log('💲 No RevenueCat customer data found, checking user document');
        }
        
        // If no RevenueCat data or not premium, check user document as fallback
        const userDocRef = db.collection('users').doc(uid);
        let userDoc;
        
        try {
            userDoc = await userDocRef.get();
        } catch (error) {
            console.log('💲 Error fetching user document:', error);
            // Default to free tier if we can't check
            return false;
        }
        
        if (userDoc && userDoc.exists) {
            const userData = userDoc.data();
            console.log('💲 User document data:', userData);
            
            // Check for premium status flag in user data
            if (userData?.isPremium === true || userData?.subscriptionTier === 'premium') {
                console.log('💲 User has premium status via user document');
                return true;
            }
        } else {
            console.log('💲 No user document found');
        }
        
        console.log('💲 User does not have premium subscription');
        return false;
    } catch (error) {
        console.error('❌ Error checking subscription status:', error);
        // Default to allowing access if there's an error checking
        return false;
    }
}

// Check message limits for free tier users
async function checkMessageLimits(uid: string): Promise<boolean> {
    try {
        console.log('🔢 Checking message limits for user:', uid);
        
        const userRef = db.collection('users').doc(uid);
        let userDoc;
        
        try {
            userDoc = await userRef.get();
        } catch (error) {
            console.log('🔢 Error fetching user document for message limits:', error);
            // Default to allowing access if we can't check
            return true;
        }
        
        if (userDoc && userDoc.exists) {
            const userData = userDoc.data();
            const messageCount = userData?.messageCount || 0;
            const messageLimit = 30; // Free tier message limit
            
            console.log('🔢 User message count:', messageCount, 'limit:', messageLimit);
            
            // Return true if user is within limits
            return messageCount < messageLimit;
        }
        
        // Default to allowing if no user document exists yet
        console.log('🔢 No existing message count found, allowing as new user');
        return true;
    } catch (error) {
        console.error('❌ Error checking message limits:', error);
        // Default to allowing access if there's an error checking
        return true;
    }
}

// Chat History Function
export const getChatHistoryV2 = onCall({
  region: 'us-central1',
}, async (request) => {
    try {
        // Debug log
        console.log('📱 Fetching chat history...');
        
        // Check authentication
        if (!request.auth) {
            throw new Error('User must be authenticated');
        }
        
        const uid = request.auth.uid;
        console.log('👤 User authenticated:', { userId: uid, token: request.auth.token });
        
        try {
            console.log('🔍 Attempting to query Firestore users collection for user:', uid);
            const snapshot = await db
                .collection('users')
                .doc(uid)
                .collection('conversations')
                .orderBy('lastUpdated', 'desc')
                .limit(50)
                .get();
            
            console.log('✅ Firestore query successful with docs count:', snapshot.docs.length);
            
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
            // Return empty array as fallback
            return [];
        }
    } catch (error) {
        console.error('❌ Error fetching chat history:', error);
        throw new Error('Failed to fetch chat history');
    }
});

// Chat Message Function
export const processChatMessageV2 = onCall({
    region: 'us-central1',
    secrets: [geminiSecretKey],
}, async (request) => {
    try {
        // Debug log
        console.log('💬 Processing chat message...');
        
        // Check authentication
        if (!request.auth) {
            throw new Error('User must be authenticated');
        }
        
        const data = request.data;
        
        // Validate message
        if (!data.message) {
            throw new Error('Message is required');
        }
        
        const { message, conversationId } = data;
        const uid = request.auth.uid;
        
        // Debug log with authentication info
        console.log('👤 User authenticated:', { 
            userId: uid,
            provider: request.auth.token.firebase?.sign_in_provider || 'unknown',
            email: request.auth.token.email || 'none'
        });
        
        // Check if user has premium subscription
        const isPremium = await checkUserSubscription(uid);
        console.log('💲 User subscription status:', isPremium ? 'Premium' : 'Free');
        
        // If user is not premium, check message limits
        if (!isPremium) {
            const withinLimits = await checkMessageLimits(uid);
            if (!withinLimits) {
                console.log('🚫 Free tier user has exceeded message limit');
                throw new Error('Message limit exceeded. Please upgrade to premium for unlimited messages.');
            }
        }
        
        // Debug log
        console.log('💬 Processing request:', {
            userId: uid,
            messageLength: message.length,
            conversationId: conversationId || 'new',
            subscription: isPremium ? 'Premium' : 'Free'
        });
        
        // Get or create conversation
        console.log('🔍 Creating conversation reference for user:', uid);
        const conversationRef = conversationId
            ? db
                .collection('users')
                .doc(uid)
                .collection('conversations')
                .doc(conversationId)
            : db
                .collection('users')
                .doc(uid)
                .collection('conversations')
                .doc();
        
        console.log('🔍 Attempting to get conversation document:', conversationRef.path);
        
        // Get conversation history
        let conversationData: ConversationData = { messages: [] };
        try {
            const conversationDoc = await conversationRef.get();
            if (conversationDoc.exists) {
                const data = conversationDoc.data();
                if (data && data.messages) {
                    conversationData = data as ConversationData;
                }
            }
            console.log('✅ Conversation document retrieved successfully');
        } catch (error) {
            console.log('⚠️ Error retrieving conversation document:', error);
            // Continue with empty conversation
        }
        
        // Add user message
        const userMessage = {
            role: 'user',
            content: message,
            timestamp: new Date().toISOString()
        };
        
        // Get API key from Secret Manager
        // Rule: Always add debug logs for easier debug
        console.log('🤖 Initializing Gemini AI with Secret Manager key...');
        
        try {
            // Get the API key using the defineSecret API
            const apiKey = geminiSecretKey.value();
            
            // Debug logs for the API key
            if (!apiKey) {
                console.error('❌ Gemini API key is not found');
                throw new Error('API key not found');
            }
            
            console.log('✅ Successfully retrieved API key, length:', apiKey.length);
            
            const genAI = new GoogleGenerativeAI(apiKey);
            // Updated model name - Gemini 1.5 Pro is the current model name
            const model = genAI.getGenerativeModel({ model: 'gemini-1.5-pro' });
            
            // Generate response using Gemini
            console.log('🤖 Generating response with Gemini...');
            const result = await model.generateContent(message);
            const response = result.response.text();
            console.log('✅ Gemini response generated successfully');
            
            // Add assistant message
            const assistantMessage = {
                role: 'assistant',
                content: response,
                timestamp: new Date().toISOString()
            };
            
            // Update conversation
            try {
                console.log('📝 Updating conversation in Firestore:', conversationRef.path);
                await conversationRef.set({
                    messages: [...conversationData.messages, userMessage, assistantMessage],
                    lastUpdated: FieldValue.serverTimestamp()
                }, { merge: true });
                console.log('✅ Conversation updated successfully');
            } catch (error) {
                console.error('❌ Error updating conversation:', error);
                // Continue without saving conversation
            }
            
            // Update user's message count
            try {
                console.log('📝 Updating user message count in Firestore');
                await db
                    .collection('users')
                    .doc(uid)
                    .set({
                        messageCount: FieldValue.increment(1),
                        lastActive: FieldValue.serverTimestamp()
                    }, { merge: true });
                console.log('✅ User message count updated successfully');
            } catch (error) {
                console.error('❌ Error updating user message count:', error);
                // Continue without updating message count
            }
            
            // Debug log
            console.log('💬 Message processed successfully');
            
            return {
                role: 'assistant',
                message: response,
                response: response,
                conversationId: conversationRef.id
            };
        } catch (error) {
            console.error('❌ Error with Gemini API:', error);
            throw new Error('Failed to generate AI response. Please try again later.');
        }
    } catch (error) {
        console.error('❌ Error processing message:', error);
        throw new Error('Failed to process message');
    }
});

// Generate a spiritual quote using Gemini based on previous messages
// Rule: The fewer lines of code is better
async function generateSpiritualQuote(previousMessages: string[]): Promise<string> {
    try {
        // Debug log
        console.log('🌟 Generating spiritual quote based on messages:', previousMessages.length > 0);
        
        // Get the API key using the defineSecret API
        const apiKey = geminiSecretKey.value();
        
        if (!apiKey) {
            console.error('❌ Gemini API key is not found');
            throw new Error('API key not found');
        }
        
        // Initialize Gemini
        const genAI = new GoogleGenerativeAI(apiKey);
        const model = genAI.getGenerativeModel({ model: 'gemini-1.5-pro' });
        
        // Create prompt based on whether we have previous messages
        let prompt = '';
        
        if (previousMessages && previousMessages.length > 0) {
            // Create a prompt that incorporates user messages
            prompt = `Based on these previous messages from a user of a spiritual app: "${previousMessages.join('" "')}",
            create a short, uplifting spiritual quote or message (max 100 characters) that would be meaningful to them. 
            The quote should be general enough to be appropriate as a daily notification. 
            Include only the quote text without quotation marks or attribution.`;
            
            console.log('🌟 Creating personalized quote based on user messages');
        } else {
            // Generic prompt for users without message history
            prompt = `Create a short, uplifting spiritual or biblical quote or message (max 100 characters) that would be 
            meaningful to send as a daily notification to a user of a spiritual app.
            Include only the quote text without quotation marks or attribution.`;
            
            console.log('🌟 Creating generic quote (no user messages available)');
        }
        
        // Generate response using Gemini
        console.log('🤖 Generating quote with Gemini...');
        const result = await model.generateContent(prompt);
        const quote = result.response.text().trim();
        
        // Ensure the quote isn't too long for a notification
        const finalQuote = quote.length > 150 ? quote.substring(0, 147) + '...' : quote;
        
        console.log('✅ Generated quote:', finalQuote);
        return finalQuote;
    } catch (error) {
        console.error('❌ Error generating quote:', error);
        return "Reflect on your spiritual journey today. Each step brings you closer to understanding.";
    }
}

// Rule: Always add debug logs
// Scheduled Daily Quote Sender - Run once per hour
export const scheduledDailyQuotes = onSchedule({
    schedule: '0 * * * *', // Every hour at minute 0
    region: 'us-central1',
    secrets: [geminiSecretKey],
    timeZone: 'UTC',
}, async (event): Promise<void> => {
    try {
        // Debug log - clear and detailed execution start
        console.log('⏰ [QUOTE JOB] Starting scheduled quotes job:', event.jobName, 'at', new Date().toISOString());
        
        // First get all users instead of querying devices directly
        console.log('👥 [QUOTE JOB] Getting all users');
        
        try {
            // Get all users
            const usersSnapshot = await db.collection('users').get();
            console.log(`👥 [QUOTE JOB] Found ${usersSnapshot.size} users in total`);
            
            if (usersSnapshot.empty) {
                console.log('⚠️ [QUOTE JOB] No users found. Ending job.');
                return;
            }
            
            let totalDevicesProcessed = 0;
            let successCount = 0;
            let errorCount = 0;
            let skippedDueToTimezone = 0;
            
            // The current UTC hour
            const currentUtcHour = new Date().getUTCHours(); 
            console.log(`⏰ [QUOTE JOB] Current UTC hour: ${currentUtcHour}`);
            
            // Process each user
            for (const userDoc of usersSnapshot.docs) {
                const userId = userDoc.id;
                console.log(`👤 [QUOTE JOB] Processing user ${userId}`);
                
                try {
                    // For each user, get their devices with notifications enabled
                    const devicesSnapshot = await db.collection('users')
                        .doc(userId)
                        .collection('devices')
                        .where('notificationsEnabled', '==', true)
                        .get();
                    
                    if (devicesSnapshot.empty) {
                        console.log(`📱 [QUOTE JOB] Skipping user ${userId} - no devices with notifications enabled`);
                        continue;
                    }
                    
                    // Process all devices to find valid timezone information
                    const devices = devicesSnapshot.docs.map(doc => ({
                        token: doc.id,
                        path: doc.ref.path,
                        timeZone: doc.data().timeZone,
                        timeZoneOffset: doc.data().timeZoneOffset,
                        lastNotified: doc.data().lastNotified || null
                    }));
                    
                    if (devices.length === 0) {
                        console.log(`📱 [QUOTE JOB] Skipping user ${userId} - no valid devices found`);
                        continue;
                    }
                    
                    console.log(`📱 [QUOTE JOB] Found ${devices.length} devices with notifications enabled for user ${userId}`);
                    
                    // Use the first device with valid timezone data to determine local time
                    // Most users will have the same timezone for all their devices
                    let userTimeZoneOffset = 0;
                    let userLocalHour = currentUtcHour;
                    
                    // Try to find a device with timezone information
                    const deviceWithTimezone = devices.find(d => d.timeZoneOffset !== undefined);
                    if (deviceWithTimezone) {
                        userTimeZoneOffset = deviceWithTimezone.timeZoneOffset || 0;
                        userLocalHour = (currentUtcHour + userTimeZoneOffset + 24) % 24; // Ensure it's 0-23
                        console.log(`⏰ [QUOTE JOB] User ${userId} timezone offset: ${userTimeZoneOffset}, local hour: ${userLocalHour}`);
                    } else {
                        console.log(`⏰ [QUOTE JOB] No timezone info for user ${userId}, using UTC`);
                    }
                    
                    // Check if it's an appropriate time to send notification
                    // Primary sending window: 7am-9am local time
                    // Secondary window: 6pm-8pm local time
                    const isPrimaryWindow = userLocalHour >= 7 && userLocalHour <= 9;
                    const isSecondaryWindow = userLocalHour >= 18 && userLocalHour <= 20;
                    
                    // Add randomization - only send to ~50% of eligible users in each run to spread out notifications
                    const shouldRandomize = Math.random() < 0.5;
                    
                    if (!isPrimaryWindow && !isSecondaryWindow) {
                        console.log(`⏰ [QUOTE JOB] Skipping user ${userId} - outside notification windows (local hour: ${userLocalHour})`);
                        skippedDueToTimezone++;
                        continue;
                    }
                    
                    if (shouldRandomize) {
                        console.log(`⏰ [QUOTE JOB] Skipping user ${userId} - randomization (will try again next hour)`);
                        skippedDueToTimezone++;
                        continue;
                    }
                    
                    // Check if we've already sent a notification today
                    // Get today's date in user's timezone
                    const now = new Date();
                    const userDate = new Date(now.getTime() + userTimeZoneOffset * 3600000);
                    const userToday = userDate.toISOString().split('T')[0]; // YYYY-MM-DD
                    
                    // Check if this user has received a notification today already
                    // First check the latest record in dailyQuotes collection
                    const todayQuotesSnapshot = await db.collection('users')
                        .doc(userId)
                        .collection('dailyQuotes')
                        .where('sentVia', '==', 'notification')
                        .orderBy('timestamp', 'desc')
                        .limit(1)
                        .get();
                    
                    let alreadySentToday = false;
                    if (!todayQuotesSnapshot.empty) {
                        const latestQuote = todayQuotesSnapshot.docs[0].data();
                        if (latestQuote.timestamp) {
                            const quoteDate = latestQuote.timestamp.toDate();
                            const quoteDateStr = quoteDate.toISOString().split('T')[0]; // YYYY-MM-DD
                            
                            if (quoteDateStr === userToday) {
                                console.log(`⏰ [QUOTE JOB] User ${userId} already received notification today at ${quoteDate.toISOString()}`);
                                alreadySentToday = true;
                            }
                        }
                    }
                    
                    if (alreadySentToday) {
                        console.log(`⏰ [QUOTE JOB] Skipping user ${userId} - already sent notification today`);
                        skippedDueToTimezone++;
                        continue;
                    }
                    
                    // At this point, we've decided to send a notification to this user
                    console.log(`⏰ [QUOTE JOB] Sending notification to user ${userId} (local hour: ${userLocalHour})`);
                    
                    totalDevicesProcessed += devices.length;
                    
                    // Fetch user's chat history for personalization
                    let userMessages: string[] = [];
                    try {
                        // Get most recent conversations
                        const conversationsSnapshot = await db.collection('users')
                            .doc(userId)
                            .collection('conversations')
                            .orderBy('lastUpdated', 'desc')
                            .limit(3)
                            .get();
                        
                        // Extract user messages from conversations
                        for (const convoDoc of conversationsSnapshot.docs) {
                            const convoData = convoDoc.data();
                            if (convoData.messages && Array.isArray(convoData.messages)) {
                                // Get only user messages, not assistant responses
                                const messages = convoData.messages
                                    .filter((msg: any) => msg.role === 'user' && msg.content)
                                    .map((msg: any) => msg.content);
                                userMessages = [...userMessages, ...messages];
                            }
                        }
                        
                        // Limit to 5 most recent messages to keep context manageable
                        userMessages = userMessages.slice(0, 5);
                        
                        console.log(`💬 [QUOTE JOB] Found ${userMessages.length} messages for personalization for user ${userId}`);
                    } catch (historyError) {
                        console.error(`❌ [QUOTE JOB] Error fetching chat history for ${userId}:`, historyError);
                        // Continue with empty messages array - will fall back to generic quote
                    }
                    
                    // Generate a quote - simple default
                    let quote = "May your day be filled with peace and spiritual connection.";
                    
                    try {
                        // Generate quote based on chat history or default
                        quote = await generateSpiritualQuote(userMessages);
                        console.log(`✍️ [QUOTE JOB] Generated quote for user ${userId}: ${quote}`);
                    } catch (quoteError) {
                        console.error(`❌ [QUOTE JOB] Error generating quote for ${userId}:`, quoteError);
                        // Continue with default quote
                    }
                    
                    // Save quote to user's history
                    let quoteId: string | null = null;
                    try {
                        const quoteRef = await userDoc.ref.collection('dailyQuotes').add({
                            quote,
                            timestamp: FieldValue.serverTimestamp(),
                            sentVia: 'notification',
                            isFavorite: false
                        });
                        quoteId = quoteRef.id;
                        console.log(`💾 [QUOTE JOB] Saved quote to history for user ${userId}, id: ${quoteId}`);
                    } catch (saveError) {
                        console.error(`❌ [QUOTE JOB] Error saving quote to history for ${userId}:`, saveError);
                        // Continue to notification - don't block notification on save error
                    }
                    
                    // Send notifications to all user's devices individually
                    console.log(`📤 [QUOTE JOB] Sending to ${devices.length} devices for user ${userId}`);
                    
                    // Process each device
                    for (const device of devices) {
                        try {
                            // Reference to the device document
                            const deviceRef = db.doc(device.path);
                            
                            // Atomically increment the badge count in Firestore
                            console.log(`📊 [QUOTE JOB] Attempting to increment badge for device: ${device.token.substring(0, 10)}...`);
                            await deviceRef.update({
                                badgeCount: FieldValue.increment(1),
                                lastNotified: FieldValue.serverTimestamp(),
                                lastUpdated: FieldValue.serverTimestamp()
                            });
                            console.log(`✅ [QUOTE JOB] Atomically incremented badge count in Firestore.`);

                            // Now, read the updated device document to get the new badge count
                            let newBadgeCount = 1; // Default to 1 if read fails
                            try {
                                const updatedDeviceDoc = await deviceRef.get();
                                if (updatedDeviceDoc.exists) {
                                    newBadgeCount = updatedDeviceDoc.data()?.badgeCount || 1;
                                    console.log(`📊 [QUOTE JOB] Read updated badge count: ${newBadgeCount}`);
                                } else {
                                     console.warn(`⚠️ [QUOTE JOB] Device doc not found after update for token: ${device.token.substring(0, 10)}...`);
                                }
                            } catch (readError) {
                                console.error(`❌ [QUOTE JOB] Error reading updated badge count:`, readError);
                                // Continue with default badge count 1
                            }
                            
                            // Create message payload with the newly read badge count
                            const message = {
                                token: device.token,
                                notification: {
                                    title: 'Your Daily Spiritual Message',
                                    body: quote,
                                },
                                data: {
                                    type: 'daily_quote',
                                    quote: quote,
                                    source: 'scheduled',
                                    timestamp: new Date().toISOString(),
                                    quoteId: quoteId || '',
                                    badgeCount: newBadgeCount.toString() // Use newly read count
                                },
                                // Critical for iOS background delivery
                                apns: {
                                    headers: {
                                        'apns-priority': '10',  // High priority
                                        'apns-push-type': 'alert'
                                    },
                                    payload: {
                                        aps: {
                                            'content-available': 1,
                                            'sound': 'default',
                                            'badge': newBadgeCount, // Use newly read count
                                            'mutable-content': 1
                                        }
                                    }
                                },
                                // Android specific settings
                                android: {
                                    priority: 'high' as const,
                                    notification: {
                                        sound: 'default',
                                        channelId: 'daily_quotes',
                                        priority: 'high' as const,
                                        defaultSound: true,
                                        visibility: 'public' as const
                                    }
                                }
                            };
                            
                            // Send the notification
                            console.log(`📤 [QUOTE JOB] Sending to token: ${device.token.substring(0, 10)}...`);
                            const messageId = await messaging.send(message);
                            
                            console.log(`✅ [QUOTE JOB] Successfully sent to device ${device.token.substring(0, 10)}..., messageId: ${messageId}`);
                            successCount++;
                        } catch (sendError: any) {
                            console.error(`❌ [QUOTE JOB] Failed to send to device ${device.token.substring(0, 10)}...:`, 
                                sendError.message || sendError);
                            
                            // Handle token not registered
                            if (sendError.code === 'messaging/registration-token-not-registered') {
                                console.log(`🧹 [QUOTE JOB] Removing invalid token: ${device.token.substring(0, 10)}...`);
                                try {
                                    // Delete the invalid device document
                                    await db.doc(device.path).delete();
                                    console.log(`🧹 [QUOTE JOB] Successfully removed invalid token document`);
                                } catch (deleteError) {
                                    console.error(`❌ [QUOTE JOB] Error deleting invalid token:`, deleteError);
                                }
                            }
                            
                            errorCount++;
                        }
                    }
                    
                    console.log(`📊 [QUOTE JOB] Completed processing user ${userId}`);
                    
                } catch (userError) {
                    console.error(`❌ [QUOTE JOB] Error processing user ${userId}:`, userError);
                    // Continue with next user
                }
            }
            
            console.log('✅ [QUOTE JOB] Completed scheduled quotes job:', {
                usersProcessed: usersSnapshot.size,
                totalDevices: totalDevicesProcessed,
                successfulNotifications: successCount,
                failedNotifications: errorCount,
                skippedDueToTimezone: skippedDueToTimezone
            });
            
        } catch (queryError) {
            console.error('❌ [QUOTE JOB] Error querying users:', queryError);
            throw queryError;
        }
    } catch (error) {
        console.error('❌ [QUOTE JOB] Fatal error in scheduled job:', error);
        throw error;
    }
});