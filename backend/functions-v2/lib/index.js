import { initializeApp } from 'firebase-admin/app';
import { getFirestore, FieldValue } from 'firebase-admin/firestore';
import { getAuth } from 'firebase-admin/auth';
import { onCall, HttpsError, onRequest } from 'firebase-functions/v2/https';
import { onSchedule } from 'firebase-functions/v2/scheduler';
import { GoogleGenerativeAI } from '@google/generative-ai';
import { defineSecret } from 'firebase-functions/params';
import { getMessaging } from 'firebase-admin/messaging';
import { CloudTasksClient } from '@google-cloud/tasks';
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
// Get Auth instance
const auth = getAuth();
console.log('🔑 Firebase Auth Admin initialized');
// Initialize Cloud Tasks Client
const tasksClient = new CloudTasksClient();
const project = process.env.GCLOUD_PROJECT;
const location = 'us-central1';
const queue = 'daily-quote-notifications';
// Construct the fully qualified queue name.
const parent = tasksClient.queuePath(project || '', location, queue);
console.log('✅ Cloud Tasks Client initialized for queue:', parent);
// Define a limit specifically for anonymous users
const ANONYMOUS_MESSAGE_LIMIT = 2; // Limit set to 3
// Check if user has premium subscription
async function checkUserSubscription(uid) {
    try {
        // Debug log
        console.log('💲 Checking subscription status for user:', uid);
        // First check RevenueCat customers collection
        const revenueCatCustomerRef = db.collection('customers').doc(uid);
        let revenueCatData;
        try {
            revenueCatData = await revenueCatCustomerRef.get();
        }
        catch (error) {
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
        }
        else {
            console.log('💲 No RevenueCat customer data found, checking user document');
        }
        // If no RevenueCat data or not premium, check user document as fallback
        const userDocRef = db.collection('users').doc(uid);
        let userDoc;
        try {
            userDoc = await userDocRef.get();
        }
        catch (error) {
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
        }
        else {
            console.log('💲 No user document found');
        }
        console.log('💲 User does not have premium subscription');
        return false;
    }
    catch (error) {
        console.error('❌ Error checking subscription status:', error);
        // Default to allowing access if there's an error checking
        return false;
    }
}
// Check message limits for free tier users
async function checkMessageLimits(uid) {
    try {
        console.log('🔢 Checking message limits for user:', uid);
        const userRef = db.collection('users').doc(uid);
        let userDoc;
        try {
            userDoc = await userRef.get();
        }
        catch (error) {
            console.log('🔢 Error fetching user document for message limits:', error);
            // Default to allowing access if we can't check
            return true;
        }
        if (userDoc && userDoc.exists) {
            const userData = userDoc.data();
            const messageCount = userData?.messageCount || 0;
            const messageLimit = 5; // Free tier lifetime message limit
            console.log('🔢 User lifetime message count:', messageCount, 'limit:', messageLimit);
            // Return true if user is within limits
            return messageCount < messageLimit;
        }
        // Default to allowing if no user document exists yet (first message)
        console.log('🔢 No existing message count found, allowing first message');
        return true; // Allow the first message which will increment the count to 1
    }
    catch (error) {
        console.error('❌ Error checking message limits:', error);
        // Default to allowing access if there's an error checking
        return true;
    }
}
// Chat History Function
export const getChatHistoryV2 = onCall({
    region: 'us-central1',
    enforceAppCheck: true,
}, async (request) => {
    try {
        console.log('📱 Fetching chat history...');
        if (!request.auth) {
            console.error('❌ Chat history requested without authentication.');
            throw new HttpsError('unauthenticated', 'User must be authenticated.');
        }
        // --- Anonymous User Check ---
        const isAnonymous = request.auth.token.firebase?.sign_in_provider === 'anonymous';
        if (isAnonymous) {
            console.log('🚫 Anonymous user attempted to fetch chat history. Denying access.');
            // Return empty array or throw an error - returning empty is often better UI
            // throw new HttpsError('permission-denied', 'Sign in to view chat history.');
            return []; // Return empty history for anonymous users
        }
        // --- End Anonymous User Check ---
        const uid = request.auth.uid;
        console.log('👤 Authenticated user requesting history:', { userId: uid });
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
        }
        catch (error) {
            console.error('❌ Error fetching chat history:', error);
            // Return empty array as fallback
            return [];
        }
    }
    catch (error) {
        console.error('❌ Error fetching chat history:', error);
        throw new Error('Failed to fetch chat history');
    }
});
// Generate a meaningful title for a conversation based on user message and AI response
async function generateConversationTitle(userMessage, aiResponse) {
    try {
        console.log('📝 Generating conversation title from:', {
            userMessage: userMessage.substring(0, 50) + '...',
            aiResponse: aiResponse.substring(0, 50) + '...'
        });
        // Get the API key using the defineSecret API
        const apiKey = geminiSecretKey.value();
        if (!apiKey) {
            console.error('❌ Gemini API key is not found');
            return "Spiritual Conversation";
        }
        // Initialize Gemini with the more capable model
        const genAI = new GoogleGenerativeAI(apiKey);
        const model = genAI.getGenerativeModel({ model: 'gemini-1.5-pro' });
        // Create improved prompt for title generation
        const prompt = `Create a meaningful, spiritual conversation title (4-5 words max) that captures the essence of this conversation:

User's Message: "${userMessage}"
AI's Response: "${aiResponse}"

Guidelines:
- Make it spiritual and meaningful
- Focus on the core theme or lesson
- Keep it concise (4-5 words max)
- Make it unique and specific to this conversation
- Do not include quotes or special characters

Examples of good titles:
- Finding Inner Peace
- Understanding God's Love
- Prayer Guidance
- Seeking Forgiveness
- Spiritual Growth Journey

Return only the title, nothing else.`;
        // Add detailed logging for the prompt
        console.log('📝 Full prompt for title generation:');
        console.log('----------------------------------------');
        console.log(prompt);
        console.log('----------------------------------------');
        console.log('📝 Prompt components:');
        console.log('- User message length:', userMessage.length);
        console.log('- AI response length:', aiResponse.length);
        console.log('- Total prompt length:', prompt.length);
        // Generate title using Gemini
        console.log('🤖 Generating title with Gemini 1.5 Pro...');
        const result = await model.generateContent(prompt);
        const title = result.response.text().trim();
        console.log('📝 Raw title from Gemini:', title);
        // Ensure the title isn't too long and remove quotes if present
        const cleanTitle = title.replace(/["']/g, '').trim();
        const finalTitle = cleanTitle.length > 30 ? cleanTitle.substring(0, 27) + '...' : cleanTitle;
        console.log('✅ Generated title:', finalTitle);
        return finalTitle;
    }
    catch (error) {
        console.error('❌ Error generating title:', error);
        // Create a simple title from the first few words of the user message
        const words = userMessage.split(' ').slice(0, 4);
        const fallbackTitle = words.join(' ') + (words.length > 4 ? '...' : '');
        console.log('📝 Using fallback title:', fallbackTitle);
        return fallbackTitle;
    }
}
// Chat Message Function
export const processChatMessageV2 = onCall({
    region: 'us-central1',
    secrets: [geminiSecretKey],
    enforceAppCheck: true,
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
        // --- Get full user record to check providerData for anonymity ---
        let isEffectivelyAnonymous = false;
        let isPremium = false; // Determine premium status later
        try {
            const authUser = await getAuth().getUser(uid);
            isEffectivelyAnonymous = authUser.providerData.length === 0;
            console.log(`👤 User record fetched: UID=${uid}, ProviderData empty=${isEffectivelyAnonymous}`);
        }
        catch (userError) {
            console.error(`❌ Error fetching auth user record for ${uid}:`, userError);
            // If we can't fetch the user, treat as non-anonymous and non-premium for safety
            // Or throw an error if this shouldn't happen
            throw new HttpsError('internal', 'Could not verify user authentication status.');
        }
        // --- End user record fetch ---
        // --- Anonymous User Limit Check ---
        // Use the isEffectivelyAnonymous flag derived from providerData
        if (isEffectivelyAnonymous) {
            console.log('🕵️ User is effectively anonymous. Checking message limits.');
            const userRef = db.collection('users').doc(uid);
            let anonymousMessageCount = 0;
            try {
                const userDoc = await userRef.get();
                if (userDoc.exists) {
                    anonymousMessageCount = userDoc.data()?.anonymousMessageCount || 0;
                }
                console.log(`🕵️ Anonymous message count: ${anonymousMessageCount}/${ANONYMOUS_MESSAGE_LIMIT}`);
                // *** Check against the limit ***
                if (anonymousMessageCount >= ANONYMOUS_MESSAGE_LIMIT) {
                    console.log('🚫 Anonymous user has exceeded message limit.');
                    // --- RETURN THE CORRECT ANONYMOUS LIMIT MESSAGE --- 
                    throw new HttpsError('resource-exhausted', 'You have reached the message limit for anonymous access. Please sign up or log in to continue chatting.');
                }
                // --- Increment anonymous count --- 
                // Do this *before* calling Gemini, outside the try/catch for limit check
                // Ensures count increments even if Gemini fails later
                await userRef.set({ anonymousMessageCount: FieldValue.increment(1) }, { merge: true });
                console.log(`🕵️ Incremented anonymousMessageCount for ${uid}`);
                // --- End Increment --- 
            }
            catch (error) {
                console.error('❌ Error fetching/updating user data for anonymous limit check:', error);
                throw new HttpsError('internal', 'Could not verify or update usage limits.');
            }
        }
        else {
            // --- Authenticated User Limit Check (Only if NOT anonymous) ---
            console.log('✅ User is not anonymous. Checking subscription and free limits.');
            isPremium = await checkUserSubscription(uid); // Check premium status only for non-anonymous
            console.log('💲 User subscription status:', isPremium ? 'Premium' : 'Free');
            if (!isPremium) {
                const withinLimits = await checkMessageLimits(uid);
                if (!withinLimits) {
                    console.log('🚫 Authenticated free tier user has exceeded lifetime message limit');
                    // --- RETURN THE AUTHENTICATED FREE LIMIT MESSAGE --- 
                    throw new HttpsError('resource-exhausted', 'You have reached the message limit for the free tier. Please upgrade to premium for unlimited messages.');
                }
                // --- Increment authenticated count (only if within limits) --- 
                try {
                    await db.collection('users').doc(uid).set({ messageCount: FieldValue.increment(1), lastActive: FieldValue.serverTimestamp() }, { merge: true });
                    console.log(`✅ Incremented authenticated messageCount for ${uid}`);
                }
                catch (error) {
                    console.error('❌ Error updating authenticated message count:', error);
                    // Decide if you want to proceed or throw error
                }
                // --- End Increment --- 
            }
            // --- End Authenticated User Limit Check ---
        }
        // --- End Limit Checks Combination ---
        // App Check already enforced
        // We already determined premium status for non-anonymous users above
        // No need to call checkUserSubscription or checkMessageLimits again here.
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
        let conversationData = { messages: [] };
        try {
            const conversationDoc = await conversationRef.get();
            if (conversationDoc.exists) {
                const data = conversationDoc.data();
                if (data && data.messages) {
                    conversationData = data;
                }
            }
            console.log('✅ Conversation document retrieved successfully');
        }
        catch (error) {
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
                throw new HttpsError('internal', 'API key not found');
            }
            console.log('✅ Successfully retrieved API key, length:', apiKey.length);
            const genAI = new GoogleGenerativeAI(apiKey);
            // Updated model name - Using Gemini 1.5 Pro for main chat (keep this for better responses)
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
            // Generate title for new conversations or if title is missing
            let title;
            try {
                const existingTitle = conversationData.title;
                if (!existingTitle || !conversationId) {
                    console.log('📝 Generating new title for conversation');
                    title = await generateConversationTitle(message, response);
                }
                else {
                    console.log('📝 Using existing title:', existingTitle);
                    title = existingTitle;
                }
            }
            catch (error) {
                console.error('❌ Error in title generation:', error);
                title = "Spiritual Conversation";
            }
            // Update conversation with new title
            try {
                console.log('📝 Updating conversation in Firestore:', {
                    path: conversationRef.path,
                    title: title
                });
                const updateData = {
                    messages: [...conversationData.messages, userMessage, assistantMessage],
                    lastUpdated: FieldValue.serverTimestamp(),
                    title: title
                };
                await conversationRef.set(updateData, { merge: true });
                console.log('✅ Conversation updated successfully with title');
            }
            catch (error) {
                console.error('❌ Error updating conversation:', error);
                // Continue without saving conversation
            }
            // Debug log
            console.log('💬 Message processed successfully');
            return {
                role: 'assistant',
                message: response,
                response: response,
                conversationId: conversationRef.id,
                title: title
            };
        }
        catch (error) {
            console.error('❌ Error with Gemini API:', error);
            // Preserve any existing HttpsError
            if (error instanceof HttpsError) {
                console.log('🚫 Rethrowing HttpsError from Gemini call:', error.code, error.message);
                throw error;
            }
            // For other errors, use a specific HttpsError for better client handling
            throw new HttpsError('internal', 'Failed to generate AI response. Please try again later.');
        }
    }
    catch (error) {
        console.error('❌ Error processing message:', error);
        // Preserve HttpsError instances to keep error codes (especially for rate limiting)
        if (error instanceof HttpsError) {
            console.log('🚫 Rethrowing original HttpsError:', error.code, error.message);
            throw error;
        }
        // For other errors, use generic error
        throw new Error('Failed to process message');
    }
});
// Generate a spiritual quote using Gemini based on previous messages
// Rule: The fewer lines of code is better
async function generateSpiritualQuote(previousMessages) {
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
        }
        else {
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
    }
    catch (error) {
        console.error('❌ Error generating quote:', error);
        return "Reflect on your spiritual journey today. Each step brings you closer to understanding.";
    }
}
// Helper: Check if a task was already scheduled today for a specific type
async function checkTaskScheduled(userId, type, userToday) {
    const scheduledMarkerRef = db.collection('users').doc(userId).collection('scheduledTasks').doc(`${userToday}_${type}`);
    try {
        const doc = await scheduledMarkerRef.get();
        if (doc.exists) {
            console.log(`[TASK SCHEDULER] Task ${type} already scheduled today (${userToday}) for user ${userId}`);
            return true;
        }
        return false;
    }
    catch (error) {
        console.error(`[TASK SCHEDULER] Error checking schedule marker for ${userId}, type ${type}:`, error);
        return false; // Default to false if check fails
    }
}
// Helper: Mark a task as scheduled for today
async function markTaskScheduled(userId, type, userToday, scheduledTime) {
    const scheduledMarkerRef = db.collection('users').doc(userId).collection('scheduledTasks').doc(`${userToday}_${type}`);
    try {
        await scheduledMarkerRef.set({
            scheduledAt: FieldValue.serverTimestamp(),
            scheduledFor: scheduledTime,
            status: 'scheduled'
        });
        console.log(`[TASK SCHEDULER] Marked task ${type} as scheduled for ${userId} at ${scheduledTime.toISOString()}`);
    }
    catch (error) {
        console.error(`[TASK SCHEDULER] Error marking schedule marker for ${userId}, type ${type}:`, error);
    }
}
// Rule: Always add debug logs
// Scheduled Daily Quote TASK SCHEDULER - Run once per hour
export const scheduleDailyQuoteTasks = onSchedule({
    schedule: '0 * * * *', // Once per hour (at minute 0)
    region: 'us-central1',
    secrets: [geminiSecretKey],
    timeZone: 'UTC',
    // Higher timeout needed? Maybe 120s? Depends on user count.
    timeoutSeconds: 120, // Increase timeout to allow for scheduling loop
}, async (event) => {
    try {
        // Debug log
        console.log(`[TASK SCHEDULER] Starting job: ${event.jobName} at ${new Date().toISOString()}`);
        // Placeholder - REPLACE THIS!
        const taskHandlerUrl = `https://${location}-${project}.cloudfunctions.net/sendNotificationTaskHandler`;
        console.log(`[TASK SCHEDULER] Using task handler URL: ${taskHandlerUrl}`);
        if (!taskHandlerUrl || !taskHandlerUrl.startsWith('https://')) {
            console.error('[TASK SCHEDULER] FATAL: Task handler URL is missing or invalid. Cannot schedule tasks.');
            return; // Stop if URL is missing
        }
        // Get all users
        console.log('[TASK SCHEDULER] Getting all users');
        const usersSnapshot = await db.collection('users').get();
        console.log(`[TASK SCHEDULER] Found ${usersSnapshot.size} users`);
        if (usersSnapshot.empty) {
            console.log('[TASK SCHEDULER] No users found. Ending job.');
            return;
        }
        let tasksScheduledCount = 0;
        let skippedDueToLimit = 0;
        let skippedAlreadyScheduled = 0;
        let errorsScheduling = 0;
        const FREE_QUOTE_LIMIT = 6;
        const now = new Date();
        const currentUtcHour = now.getUTCHours();
        console.log(`[TASK SCHEDULER] Current UTC hour: ${currentUtcHour}`);
        // --- Define Notification Windows ---
        const morningWindowStartHourLocal = 7; // 7:00 AM Local
        const morningWindowEndHourLocal = 8; // Ends at 8:59 AM Local
        const eveningWindowStartHourLocal = 18; // 6:00 PM Local
        const eveningWindowEndHourLocal = 19; // Ends at 7:59 PM Local
        for (const userDoc of usersSnapshot.docs) {
            const userId = userDoc.id;
            const userData = userDoc.data() || {};
            try {
                // Check subscription & Limits (only if scheduling needed)
                const isPremium = await checkUserSubscription(userId);
                const dailyQuoteCount = userData.dailyQuoteCount || 0;
                if (!isPremium && dailyQuoteCount >= FREE_QUOTE_LIMIT) {
                    // console.log(`[TASK SCHEDULER] Skipping user ${userId} - Free limit reached.`);
                    skippedDueToLimit++;
                    continue;
                }
                // Determine User's Local Timezone Info (only need offset)
                let userTimeZoneOffset = 0;
                const devicesSnapshot = await db.collection('users')
                    .doc(userId)
                    .collection('devices')
                    // Only need one device with timezone info
                    .where('timeZoneOffset', '!=', null)
                    .limit(1)
                    .get();
                if (!devicesSnapshot.empty) {
                    userTimeZoneOffset = devicesSnapshot.docs[0].data().timeZoneOffset || 0;
                }
                else {
                    // Check another field if offset not available
                    // const userSettings = await db.collection('users').doc(userId).collection('settings').doc('prefs').get();
                    // if (userSettings.exists && userSettings.data()?.timeZoneOffset !== undefined) {
                    //      userTimeZoneOffset = userSettings.data()?.timeZoneOffset;
                    // } else {
                    console.log(`[TASK SCHEDULER] No timezone info for user ${userId}, using UTC 0.`);
                    // }
                }
                const userLocalHour = (currentUtcHour + userTimeZoneOffset + 24) % 24;
                const userDate = new Date(now.getTime() + userTimeZoneOffset * 3600000);
                const userToday = userDate.toISOString().split('T')[0]; // YYYY-MM-DD
                // console.log(`[TASK SCHEDULER] User ${userId} Local Hour: ${userLocalHour}, Date: ${userToday}, Offset: ${userTimeZoneOffset}`);
                // --- Determine if Morning or Evening Task needs scheduling ---
                let targetSendType = null;
                let targetWindowStartHour = null;
                let targetWindowEndHour = null;
                // Should we schedule a MORNING task?
                // Check if the *next* hour falls into the morning window (e.g., if current local hour is 6, next is 7)
                if (userLocalHour >= morningWindowStartHourLocal - 1 && userLocalHour <= morningWindowEndHourLocal) {
                    const alreadyScheduled = await checkTaskScheduled(userId, 'notification_morning', userToday);
                    if (!alreadyScheduled) {
                        targetSendType = 'notification_morning';
                        targetWindowStartHour = morningWindowStartHourLocal;
                        targetWindowEndHour = morningWindowEndHourLocal;
                        console.log(`[TASK SCHEDULER] User ${userId} eligible for MORNING task scheduling (Local Hour: ${userLocalHour})`);
                    }
                    else {
                        skippedAlreadyScheduled++;
                    }
                }
                // Should we schedule an EVENING task? (Only if morning wasn't targeted)
                // Check if the *next* hour falls into the evening window
                if (!targetSendType && userLocalHour >= eveningWindowStartHourLocal - 1 && userLocalHour <= eveningWindowEndHourLocal) {
                    const alreadyScheduled = await checkTaskScheduled(userId, 'notification_evening', userToday);
                    if (!alreadyScheduled) {
                        targetSendType = 'notification_evening';
                        targetWindowStartHour = eveningWindowStartHourLocal;
                        targetWindowEndHour = eveningWindowEndHourLocal;
                        console.log(`[TASK SCHEDULER] User ${userId} eligible for EVENING task scheduling (Local Hour: ${userLocalHour})`);
                    }
                    else {
                        skippedAlreadyScheduled++;
                    }
                }
                // If no task needs scheduling for this user in this run, continue
                if (!targetSendType || targetWindowStartHour === null || targetWindowEndHour === null) {
                    continue;
                }
                // --- Calculate Random Send Time ---
                const randomMinutes = Math.floor(Math.random() * 120); // 0-119 minutes past window start
                const sendDate = new Date(userDate); // Use user's local date object
                // Set hour to the start of the window, then add random minutes
                sendDate.setHours(targetWindowStartHour, 0, 0, 0);
                sendDate.setMinutes(sendDate.getMinutes() + randomMinutes);
                // Ensure calculated time is not in the past relative to now
                // If it is (e.g., job runs late), schedule for minimum 5 mins from now
                const minScheduleTime = new Date(now.getTime() + 5 * 60 * 1000);
                if (sendDate.getTime() < minScheduleTime.getTime()) {
                    console.warn(`[TASK SCHEDULER] Calculated send time for ${userId} (${sendDate.toISOString()}) is in the past. Scheduling for 5 mins from now.`);
                    sendDate.setTime(minScheduleTime.getTime());
                }
                // --- Check Free Limit & Increment Count ---
                let limitReachedByThisQuote = false;
                if (!isPremium) {
                    const newDailyQuoteCount = dailyQuoteCount + 1;
                    if (newDailyQuoteCount === FREE_QUOTE_LIMIT) {
                        limitReachedByThisQuote = true;
                        console.log(`[TASK SCHEDULER] User ${userId} will reach free limit with this scheduled task.`);
                    }
                    // IMPORTANT: Increment count *before* scheduling task
                    try {
                        await userDoc.ref.update({ dailyQuoteCount: FieldValue.increment(1) });
                        console.log(`[TASK SCHEDULER] Incremented dailyQuoteCount for free user ${userId} to ${newDailyQuoteCount}`);
                    }
                    catch (updateError) {
                        console.error(`[TASK SCHEDULER] Failed to increment count for ${userId}. Skipping task creation.`, updateError);
                        errorsScheduling++;
                        continue; // Don't schedule if count fails
                    }
                }
                // --- Generate Quote ---
                // Fetch history (simplified - you might want more context)
                let userMessages = [];
                try {
                    const convos = await db.collection('users').doc(userId).collection('conversations')
                        .orderBy('lastUpdated', 'desc').limit(1).get();
                    if (!convos.empty && convos.docs[0].data()?.messages) {
                        userMessages = convos.docs[0].data().messages
                            .filter((m) => m.role === 'user').map((m) => m.content).slice(0, 3);
                    }
                }
                catch (histError) {
                    console.error(`Error fetching history for quote gen for ${userId}`, histError);
                }
                let quote = "May your day be blessed."; // Default
                try {
                    quote = await generateSpiritualQuote(userMessages);
                }
                catch (quoteError) {
                    console.error(`Error generating quote for ${userId}`, quoteError);
                }
                // --- Create Cloud Task ---
                const payload = {
                    userId: userId,
                    quote: quote,
                    sendType: targetSendType,
                    limitReached: limitReachedByThisQuote
                };
                const task = {
                    httpRequest: {
                        httpMethod: 'POST',
                        url: taskHandlerUrl,
                        body: Buffer.from(JSON.stringify(payload)).toString('base64'),
                        headers: {
                            'Content-Type': 'application/json',
                        },
                        // TODO: Add OIDC token for authentication if using Cloud Functions v2 / Cloud Run
                        // See: https://cloud.google.com/tasks/docs/creating-http-target-tasks#node.js
                        // Requires getting the service account email associated with this function
                        // oidcToken: {
                        //   serviceAccountEmail: 'YOUR_FUNCTION_SERVICE_ACCOUNT_EMAIL',
                        // },
                    },
                    scheduleTime: {
                        seconds: Math.floor(sendDate.getTime() / 1000)
                    }
                };
                try {
                    console.log(`[TASK SCHEDULER] Creating task for user ${userId}, type ${targetSendType}, scheduled for ${sendDate.toISOString()}`);
                    const [response] = await tasksClient.createTask({ parent: parent, task: task });
                    console.log(`[TASK SCHEDULER] Task ${response.name} created successfully.`);
                    tasksScheduledCount++;
                    // Mark as scheduled in Firestore AFTER successful task creation
                    await markTaskScheduled(userId, targetSendType, userToday, sendDate);
                }
                catch (error) {
                    console.error(`[TASK SCHEDULER] Failed to create task for user ${userId}:`, error);
                    errorsScheduling++;
                    // TODO: Consider rolling back the dailyQuoteCount increment if task creation fails?
                    // Requires careful handling to avoid race conditions. For now, we leave it incremented.
                }
            }
            catch (userError) {
                console.error(`[TASK SCHEDULER] Error processing user ${userId}:`, userError);
                errorsScheduling++; // Count general processing errors too
            }
        } // End user loop
        console.log('[TASK SCHEDULER] Completed job:', {
            usersProcessed: usersSnapshot.size,
            tasksScheduled: tasksScheduledCount,
            skippedAlreadyScheduled: skippedAlreadyScheduled,
            skippedDueToLimit: skippedDueToLimit,
            errorsScheduling: errorsScheduling
        });
    }
    catch (error) {
        console.error('[TASK SCHEDULER] Fatal error in scheduled job:', error);
        throw error; // Allow the job to report failure
    }
});
export const sendNotificationTaskHandler = onRequest({
    region: 'us-central1',
    // Ensure this function can be invoked by Cloud Tasks
    // You might need to configure IAM permissions separately
    // Consider adding memory/cpu options if needed
}, async (req, res) => {
    // TODO: Add verification to ensure the request comes from Cloud Tasks
    // e.g., Check for specific headers or OIDC token validation
    // See: https://cloud.google.com/functions/docs/securing/authenticating#validating_tokens
    const logPrefix = '[TASK HANDLER]';
    console.log(`${logPrefix} Received task request at ${new Date().toISOString()}`);
    try {
        // Decode payload
        let payload;
        if (req.body.message && req.body.message.data) {
            // Structure for Pub/Sub triggered tasks if used in future
            payload = JSON.parse(Buffer.from(req.body.message.data, 'base64').toString());
            console.log(`${logPrefix} Decoded Pub/Sub payload for user: ${payload.userId}`);
        }
        else if (typeof req.body === 'string') {
            // Structure for direct HTTP POST with base64 body
            payload = JSON.parse(Buffer.from(req.body, 'base64').toString());
            console.log(`${logPrefix} Decoded HTTP Base64 payload for user: ${payload.userId}`);
        }
        else if (req.body && typeof req.body === 'object' && req.body.userId) {
            // Structure for direct HTTP POST with JSON body (if Content-Type was set correctly)
            payload = req.body;
            console.log(`${logPrefix} Decoded HTTP JSON payload for user: ${payload.userId}`);
        }
        else {
            console.error(`${logPrefix} Invalid payload structure:`, req.body);
            res.status(400).send('Bad Request: Invalid payload');
            return;
        }
        const { userId, quote, sendType, limitReached } = payload;
        if (!userId || !quote || !sendType) {
            console.error(`${logPrefix} Invalid payload content: Missing fields`, payload);
            res.status(400).send('Bad Request: Missing fields in payload');
            return;
        }
        console.log(`${logPrefix} Processing task for user ${userId}, type: ${sendType}`);
        // Get user's devices
        const devicesSnapshot = await db.collection('users')
            .doc(userId)
            .collection('devices')
            .where('notificationsEnabled', '==', true)
            .get();
        if (devicesSnapshot.empty) {
            console.log(`${logPrefix} No enabled devices found for user ${userId}. Task complete.`);
            // Mark task status in Firestore if needed (optional)
            // await db.collection('users').doc(userId).collection('scheduledTasks').doc(`${userToday}_${sendType}`).update({ status: 'completed_no_devices' });
            res.status(200).send(`OK: No devices for user ${userId}`);
            return;
        }
        console.log(`${logPrefix} Found ${devicesSnapshot.size} devices for user ${userId}`);
        // Save quote to history (moved here from scheduler)
        let quoteId = null;
        try {
            const quoteRef = await db.collection('users').doc(userId).collection('dailyQuotes').add({
                quote: quote,
                timestamp: FieldValue.serverTimestamp(),
                sentVia: sendType,
                isFavorite: false,
                status: 'delivered' // Mark as delivered by task handler
            });
            quoteId = quoteRef.id;
            console.log(`${logPrefix} Saved quote to history for user ${userId}, id: ${quoteId}`);
        }
        catch (saveError) {
            console.error(`${logPrefix} Error saving quote to history for ${userId}:`, saveError);
            // Continue anyway, but log the error
        }
        // Send notifications
        let successCount = 0;
        let errorCount = 0;
        const batchSize = 500; // FCM batch limit
        const deviceDocs = devicesSnapshot.docs;
        for (let i = 0; i < deviceDocs.length; i += batchSize) {
            const batchDocs = deviceDocs.slice(i, i + batchSize);
            const messages = []; // Use any[] for flexibility with badge counts
            // Prepare messages for the batch, including badge increment and read
            for (const deviceDoc of batchDocs) {
                const deviceToken = deviceDoc.id; // Token is the doc ID
                const devicePath = deviceDoc.ref.path;
                // Atomically increment badge count
                try {
                    await db.doc(devicePath).update({ badgeCount: FieldValue.increment(1) });
                    // Read the updated count (best effort)
                    let newBadgeCount = 1;
                    try {
                        const updatedDoc = await db.doc(devicePath).get();
                        newBadgeCount = updatedDoc.data()?.badgeCount || 1;
                    }
                    catch (readError) {
                        console.error(`${logPrefix} Failed to read badge count for ${deviceToken.substring(0, 10)}...`, readError);
                    }
                    const message = {
                        token: deviceToken,
                        notification: {
                            title: 'Your Daily Spiritual Message',
                            body: quote,
                        },
                        data: {
                            type: 'daily_quote',
                            quote: quote,
                            source: 'scheduled_task', // Indicate source
                            timestamp: new Date().toISOString(),
                            quoteId: quoteId || '',
                            badgeCount: newBadgeCount.toString(),
                            limitReached: limitReached.toString()
                        },
                        apns: {
                            headers: { 'apns-priority': '5', 'apns-push-type': 'alert' }, // Use 5 for content updates/non-urgent
                            payload: { aps: { 'content-available': 1, 'sound': 'default', 'badge': newBadgeCount, 'mutable-content': 1 } }
                        },
                        android: {
                            priority: 'normal', // Use normal for background tasks
                            notification: { sound: 'default', channelId: 'daily_quotes', priority: 'default', defaultSound: true, visibility: 'public' }
                        }
                    };
                    messages.push(message);
                }
                catch (updateError) {
                    console.error(`${logPrefix} Failed to update badge count for ${deviceToken.substring(0, 10)}...`, updateError);
                    // Decide if you should still try to send? Maybe skip this token.
                }
            } // End inner loop for message prep
            // Send the batch if messages were prepared
            if (messages.length > 0) {
                try {
                    console.log(`${logPrefix} Sending batch of ${messages.length} messages for user ${userId}`);
                    const batchResponse = await messaging.sendEach(messages);
                    successCount += batchResponse.successCount;
                    errorCount += batchResponse.failureCount;
                    console.log(`${logPrefix} Batch sent. Success: ${batchResponse.successCount}, Failure: ${batchResponse.failureCount}`);
                    // Handle failures (e.g., unregistered tokens)
                    if (batchResponse.failureCount > 0) {
                        const cleanupPromises = [];
                        batchResponse.responses.forEach((resp, idx) => {
                            if (!resp.success) {
                                const errorCode = resp.error?.code;
                                const failedToken = messages[idx].token; // Get token from original message
                                console.error(`${logPrefix} Failed to send to token ${failedToken.substring(0, 10)}... Error: ${errorCode} - ${resp.error?.message}`);
                                if (errorCode === 'messaging/registration-token-not-registered' || errorCode === 'messaging/invalid-registration-token') {
                                    console.log(`${logPrefix} Scheduling cleanup for invalid token: ${failedToken.substring(0, 10)}...`);
                                    const failedDeviceDoc = batchDocs.find(doc => doc.id === failedToken);
                                    if (failedDeviceDoc) {
                                        cleanupPromises.push(db.doc(failedDeviceDoc.ref.path).delete().catch(delErr => console.error(`Failed to delete token ${failedToken}:`, delErr)));
                                    }
                                }
                            }
                        });
                        await Promise.all(cleanupPromises);
                        console.log(`${logPrefix} Invalid token cleanup complete for batch.`);
                    }
                }
                catch (batchError) {
                    console.error(`${logPrefix} Error sending batch for user ${userId}:`, batchError);
                    // Note: If sendEach fails entirely, individual errors might not be available.
                    errorCount += messages.length; // Assume all failed if the call itself failed
                }
            }
        } // End batch loop
        console.log(`${logPrefix} Finished sending for user ${userId}. Total Success: ${successCount}, Total Errors: ${errorCount}`);
        // Mark task status in Firestore if needed (optional)
        // await db.collection('users').doc(userId).collection('scheduledTasks').doc(`${userToday}_${sendType}`).update({ status: 'completed', successCount, errorCount });
        // Respond to Cloud Tasks to acknowledge processing
        res.status(200).send(`OK: Processed ${successCount} success, ${errorCount} errors for user ${userId}`);
    }
    catch (error) {
        console.error(`${logPrefix} Fatal error processing task:`, error);
        // Respond with an error status code to signal failure to Cloud Tasks
        // This might cause Cloud Tasks to retry the task depending on queue configuration
        res.status(500).send(`Internal Server Error: ${error.message || 'Unknown error'}`);
    }
});
// ---- NEW FUNCTION: Generate Custom Token for Persistent Anonymous ID ----
export const getCustomAuthTokenForAnonymousId = onCall({
    region: 'us-central1',
    enforceAppCheck: true, // Enforce App Check for security
    // No secrets needed for this function
}, async (request) => {
    const logPrefix = '[CUSTOM TOKEN]';
    // --- ADD DETAILED LOGGING HERE ---
    // console.log(`${logPrefix} Received request. Full request object:`, JSON.stringify(request, null, 2)); // <-- COMMENT THIS OUT
    // You can also log specific parts if the above is too verbose or potentially fails:
    console.log(`${logPrefix} Request data:`, JSON.stringify(request.data, null, 2)); // <-- UNCOMMENTED
    console.log(`${logPrefix} Request app check token details:`, JSON.stringify(request.app, null, 2)); // <-- UNCOMMENTED
    // --- END DETAILED LOGGING ---
    console.log(`${logPrefix} Received request.`); // Keep original log too
    // 1. Validate Request Data
    const persistentId = request.data.persistentId;
    if (!persistentId || typeof persistentId !== 'string' || persistentId.length < 36) { // Basic check (UUID length)
        console.error(`${logPrefix} Invalid or missing persistentId in request data:`, request.data);
        throw new HttpsError('invalid-argument', 'The function must be called with a valid persistentId string.');
    }
    console.log(`${logPrefix} Valid persistentId received: ${persistentId}`);
    // 2. Generate Custom Token
    try {
        console.log(`${logPrefix} Generating custom token for UID: ${persistentId}`);
        // Use the persistentId directly as the Firebase UID
        const customToken = await getAuth().createCustomToken(persistentId);
        console.log(`${logPrefix} Successfully generated custom token for UID: ${persistentId}`);
        // 3. Return Token
        return { customToken: customToken };
    }
    catch (error) {
        console.error(`${logPrefix} Error generating custom token for UID ${persistentId}:`, error);
        // Map common errors to HttpsError if needed, otherwise throw internal
        if (error.code === 'auth/invalid-argument') {
            throw new HttpsError('invalid-argument', 'The provided persistentId is invalid for Firebase Auth.');
        }
        throw new HttpsError('internal', `Failed to create custom token: ${error.message || 'Unknown error'}`);
    }
});
// --- Helper Function to Delete Collections Recursively --- 
async function deleteCollection(collectionRef, batchSize = 100) {
    const query = collectionRef.limit(batchSize);
    return new Promise((resolve, reject) => {
        deleteQueryBatch(query, resolve, reject);
    });
}
async function deleteQueryBatch(query, resolve, reject) {
    try {
        const snapshot = await query.get();
        // When there are no documents left, we are done
        if (snapshot.size === 0) {
            resolve();
            return;
        }
        // Delete documents in a batch
        const batch = db.batch();
        snapshot.docs.forEach(doc => {
            // Recursively delete subcollections first (important!)
            // For simplicity here, we assume known subcollection names.
            // A more robust solution would list subcollections dynamically.
            const subcollectionsToDelete = ['subcollection1', 'subcollection2']; // ADD ANY SPECIFIC SUBCOLLECTIONS OF THE CURRENT LEVEL IF NEEDED
            subcollectionsToDelete.forEach(subColl => {
                // Schedule deletion, but don't wait here to avoid deep nesting
                deleteCollection(doc.ref.collection(subColl)).catch(reject);
            });
            // Add the document itself to the batch delete
            batch.delete(doc.ref);
        });
        await batch.commit();
        // Recurse on the next batch
        process.nextTick(() => {
            deleteQueryBatch(query, resolve, reject);
        });
    }
    catch (error) {
        console.error("Error deleting batch: ", error);
        reject(error);
    }
}
// --- Account Deletion Function --- 
export const deleteAccountAndData = onCall({
    region: 'us-central1',
    enforceAppCheck: true,
    // Add secrets if needed for external service calls during deletion
}, async (request) => {
    const logPrefix = '[ACCOUNT DELETE]';
    console.log(`${logPrefix} Received request.`);
    // 1. Check Authentication AND Provider
    if (!request.auth) {
        console.error(`${logPrefix} User not authenticated.`);
        throw new HttpsError('unauthenticated', 'User must be authenticated to delete account.');
    }
    const uid = request.auth.uid;
    const signInProvider = request.auth.token.firebase?.sign_in_provider;
    console.log(`${logPrefix} Authenticated user: ${uid}, Provider: ${signInProvider || 'unknown'}`);
    // --- Add check for anonymous user --- 
    if (signInProvider === 'anonymous') {
        console.error(`${logPrefix} Anonymous user (${uid}) attempted account deletion. Denying.`);
        throw new HttpsError('permission-denied', 'Anonymous users cannot delete accounts. Please sign in with Google or Apple first.');
    }
    // --- End anonymous check --- 
    try {
        // Start a Firestore transaction for atomic operations where possible
        await db.runTransaction(async (transaction) => {
            console.log(`${logPrefix} Starting transaction for account deletion process`);
            const userRef = db.collection('users').doc(uid);
            // Verify user exists
            const userDoc = await transaction.get(userRef);
            if (!userDoc.exists) {
                console.warn(`${logPrefix} User document does not exist for ${uid}`);
                // Continue anyway to clean up other data
            }
            else {
                console.log(`${logPrefix} Found user document for ${uid}`);
            }
            // Mark user as being deleted (in case process fails, we know it's in progress)
            transaction.update(userRef, {
                deletionInProgress: true,
                deletionStarted: FieldValue.serverTimestamp()
            });
            console.log(`${logPrefix} Marked user account as being deleted`);
        });
        // Define subcollections to delete under users/{uid}
        const subcollections = [
            'conversations',
            'devices',
            'scheduledTasks',
            'dailyQuotes'
            // Add any other subcollections associated with the user
        ];
        // 2. Delete Subcollections Recursively
        console.log(`${logPrefix} Deleting subcollections for user ${uid}...`);
        const deletePromises = subcollections.map(async (subcollectionName) => {
            console.log(`${logPrefix}   - Deleting ${subcollectionName}...`);
            const subcollectionRef = db.collection('users').doc(uid).collection(subcollectionName);
            await deleteCollection(subcollectionRef);
            console.log(`${logPrefix}   - Finished deleting ${subcollectionName}.`);
        });
        // Wait for all subcollection deletions to complete
        await Promise.all(deletePromises);
        console.log(`${logPrefix} Finished deleting all subcollections.`);
        // 3. Check for and handle RevenueCat subscriptions
        const customerDoc = await db.collection('customers').doc(uid).get();
        if (customerDoc.exists && customerDoc.data()?.subscriptions) {
            console.log(`${logPrefix} Found RevenueCat customer data, checking for active subscriptions`);
            // Note: This is a placeholder. In a real implementation, you would:
            // 1. Use RevenueCat API to cancel subscriptions if possible
            // 2. Or flag the account for deletion in your backend systems
            console.log(`${logPrefix} Handling RevenueCat data completed`);
        }
        // 4. Delete Main User Document
        console.log(`${logPrefix} Deleting main user document: users/${uid}`);
        await db.collection('users').doc(uid).delete();
        console.log(`${logPrefix} Main user document deleted.`);
        // 5. Delete RevenueCat Customer Document
        console.log(`${logPrefix} Deleting RevenueCat document: customers/${uid}`);
        await db.collection('customers').doc(uid).delete().catch(error => {
            // Log error but don't fail the whole process if customer doc doesn't exist or fails
            console.warn(`${logPrefix} Could not delete customer document (may not exist):`, error);
        });
        console.log(`${logPrefix} RevenueCat customer document deleted (or did not exist).`);
        // 6. Delete any references in other collections
        // Example: Delete user data in shared collections like 'groups', 'communities', etc.
        // This is a placeholder - add actual collection cleanups as needed for your app
        console.log(`${logPrefix} Cleaning up user references in other collections`);
        // Example: Delete user's tasks in a "tasks" collection
        // const tasksSnapshot = await db.collection('tasks').where('userId', '==', uid).get();
        // const taskBatch = db.batch();
        // tasksSnapshot.docs.forEach(doc => taskBatch.delete(doc.ref));
        // await taskBatch.commit();
        // 7. Delete Firebase Storage Data if applicable
        // const storageBucket = admin.storage().bucket();
        // const userFilesPrefix = `userFiles/${uid}/`;
        // console.log(`${logPrefix} Deleting files from Storage at prefix: ${userFilesPrefix}`);
        // await storageBucket.deleteFiles({ prefix: userFilesPrefix });
        // console.log(`${logPrefix} Storage files deleted.`);
        // 8. Delete Firebase Auth User
        console.log(`${logPrefix} Deleting user from Firebase Authentication: ${uid}`);
        try {
            await auth.deleteUser(uid);
            console.log(`${logPrefix} Firebase Auth user deleted successfully.`);
        }
        catch (authError) {
            console.error(`${logPrefix} Error deleting Firebase Auth user:`, authError);
            // If we fail to delete the auth user but deleted their data, 
            // the account is essentially unusable but still exists
            throw new HttpsError('internal', 'Failed to delete authentication account after data was removed.');
        }
        // 9. Log success for audit purposes
        console.log(`${logPrefix} Account deletion completed successfully for user ${uid} at ${new Date().toISOString()}`);
        return {
            success: true,
            message: 'Account and all associated data deleted successfully.',
            timestamp: new Date().toISOString()
        };
    }
    catch (error) {
        console.error(`${logPrefix} Error deleting account for user ${uid}:`, error);
        // Try to mark the account as having a failed deletion attempt
        try {
            await db.collection('users').doc(uid).update({
                deletionFailed: true,
                deletionError: error.message || 'Unknown error',
                deletionAttemptedAt: FieldValue.serverTimestamp()
            });
        }
        catch (updateError) {
            console.error(`${logPrefix} Could not mark account as failed deletion:`, updateError);
        }
        // Avoid leaking internal details, throw a generic error
        throw new HttpsError('internal', `Failed to delete account: ${error.message || 'Unknown error'}`);
    }
});
//# sourceMappingURL=index.js.map