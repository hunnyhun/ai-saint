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
// --- Rate Limiting Constants ---
const IP_RATE_LIMIT_WINDOW_SECONDS = 60; // 1 minute
const IP_RATE_LIMIT_MAX_REQUESTS = 30; // Max requests per window per IP
// Define a limit specifically for anonymous users
const ANONYMOUS_MESSAGE_LIMIT = 2; // Limit set to 3
/**
 * Checks user authentication status for onCall functions.
 * Verifies authentication and identifies custom anonymous users via claims.
 *
 * @param {AuthData | undefined} auth The auth object from the request.
 * @throws {HttpsError('unauthenticated')} If the user is not authenticated.
 * @returns {Promise<UserAuthStatus>} An object containing the user's UID and anonymous status.
 */
async function checkUserAuthentication(auth) {
    const logPrefix = '[AuthCheck]';
    if (!auth) {
        console.error(`${logPrefix} User authentication data missing.`);
        throw new HttpsError('unauthenticated', 'User must be authenticated.');
    }
    const uid = auth.uid;
    const standardProvider = auth.token.firebase?.sign_in_provider;
    // *** MODIFICATION: Only check if provider is 'custom' ***
    const isAnonymous = standardProvider === 'custom';
    // Determine provider string for logging/debugging
    const provider = isAnonymous
        ? 'custom_provider' // Simplified logging
        : standardProvider || 'unknown'; // Use standard provider if known and not anon
    console.log(`${logPrefix} User verified:`, {
        userId: uid,
        provider: provider,
        isAnonymous: isAnonymous, // Use the calculated isAnonymous flag
    });
    return {
        uid,
        isAnonymous, // Return the calculated flag
    };
}
// Check if user has premium subscription
async function checkUserSubscription(uid) {
    const logPrefix = '[SubscriptionCheck]';
    try {
        console.log(`${logPrefix} Checking subscription status for user:`, uid);
        const revenueCatCustomerRef = db.collection('customers').doc(uid);
        let customerDoc;
        try {
            customerDoc = await revenueCatCustomerRef.get();
            if (!customerDoc.exists) {
                console.log(`${logPrefix} No RevenueCat customer document found for user ${uid}. Assuming free.`);
                return false; // No customer document means not premium
            }
        }
        catch (error) {
            console.error(`${logPrefix} Error fetching RevenueCat data for user ${uid}:`, error);
            // If we can't fetch the official subscription data, assume free for safety
            return false;
        }
        const customerData = customerDoc.data();
        console.log(`${logPrefix} RevenueCat customer data found for user ${uid}.`); // Simplified log
        // --- Check Subscriptions Map Directly --- 
        if (!customerData?.subscriptions) {
            console.log(`${logPrefix} No 'subscriptions' map found in customer data. Assuming free.`);
            return false;
        }
        const subscriptions = customerData.subscriptions;
        const now = new Date();
        // Define your product IDs (ensure these are correct!)
        const monthlyProductId = 'com.hunnyhun.aisaint.premium.monthly';
        const yearlyProductId = 'com.hunnyhun.aisaint.premium.yearly'; // <-- VERIFY THIS ID
        // Check monthly subscription
        const monthlySub = subscriptions[monthlyProductId];
        if (monthlySub) {
            console.log(`${logPrefix} Found monthly subscription entry.`);
            if (monthlySub.expires_date) {
                try {
                    const expiryDate = new Date(monthlySub.expires_date);
                    if (expiryDate > now) {
                        console.log(`${logPrefix} Monthly subscription is active (expires: ${monthlySub.expires_date}). User is Premium.`);
                        return true;
                    }
                    console.log(`${logPrefix} Monthly subscription expired (${monthlySub.expires_date}).`);
                }
                catch (dateError) {
                    console.error(`${logPrefix} Error parsing monthly expiry date '${monthlySub.expires_date}':`, dateError);
                }
            }
            else {
                console.log(`${logPrefix} Monthly subscription entry has no expiry date.`);
            }
        }
        else {
            console.log(`${logPrefix} No monthly subscription entry found.`);
        }
        // Check yearly subscription
        const yearlySub = subscriptions[yearlyProductId];
        if (yearlySub) {
            console.log(`${logPrefix} Found yearly subscription entry.`);
            if (yearlySub.expires_date) {
                try {
                    const expiryDate = new Date(yearlySub.expires_date);
                    if (expiryDate > now) {
                        console.log(`${logPrefix} Yearly subscription is active (expires: ${yearlySub.expires_date}). User is Premium.`);
                        return true;
                    }
                    console.log(`${logPrefix} Yearly subscription expired (${yearlySub.expires_date}).`);
                }
                catch (dateError) {
                    console.error(`${logPrefix} Error parsing yearly expiry date '${yearlySub.expires_date}':`, dateError);
                }
            }
            else {
                console.log(`${logPrefix} Yearly subscription entry has no expiry date.`);
            }
        }
        else {
            console.log(`${logPrefix} No yearly subscription entry found.`);
        }
        // If neither active subscription was found
        console.log(`${logPrefix} No active monthly or yearly subscription found based on expiry dates. User is Free.`);
        return false;
    }
    catch (error) {
        console.error(`${logPrefix} Unexpected error during subscription check for user ${uid}:`, error);
        // Default to free (false) if any unexpected error occurs during the process
        return false;
    }
}
// Check message limits for free tier users
// Modified to handle both anonymous and authenticated free users
async function checkMessageLimits(uid, isAnonymousUser) {
    try {
        const userRef = db.collection('users').doc(uid);
        let userDoc;
        // --- Anonymous User Limit Check ---
        if (isAnonymousUser) {
            console.log('🕵️ [checkMessageLimits] User is anonymous. Checking message limits.');
            let anonymousMessageCount = 0;
            try {
                userDoc = await userRef.get(); // Fetch user doc
                if (userDoc.exists) {
                    anonymousMessageCount = userDoc.data()?.anonymousMessageCount || 0;
                }
                console.log(`🕵️ [checkMessageLimits] Anonymous message count: ${anonymousMessageCount}/${ANONYMOUS_MESSAGE_LIMIT}`);
                // *** Check against the limit ***
                if (anonymousMessageCount >= ANONYMOUS_MESSAGE_LIMIT) {
                    console.log('🚫 [checkMessageLimits] Anonymous user has exceeded message limit.');
                    // *** MODIFICATION: Add details object ***
                    throw new HttpsError('resource-exhausted', 'You have reached the message limit for anonymous access. Please sign in or sign up to continue chatting.', { limitType: 'anonymous' } // Add specific detail
                    );
                }
                // If limit not reached, return true (allow message)
                console.log('✅ [checkMessageLimits] Anonymous user is within limits.');
                return true;
            }
            catch (error) {
                // Handle specific HttpsError re-throw
                if (error instanceof HttpsError) {
                    throw error; // Re-throw the specific limit error
                }
                // Handle other errors during fetch/check
                console.error('❌ [checkMessageLimits] Error fetching/checking anonymous limit:', error);
                // Decide if you want to block or allow if the check fails. Blocking is safer.
                throw new HttpsError('internal', 'Could not verify anonymous usage limits.');
            }
        }
        // --- End Anonymous User Limit Check ---
        // --- Authenticated Free User Limit Check ---
        else {
            console.log('🔢 [checkMessageLimits] Checking authenticated free user message limits for:', uid);
            try {
                // Fetch user doc if not already fetched
                if (!userDoc) {
                    userDoc = await userRef.get();
                }
                if (userDoc && userDoc.exists) {
                    const userData = userDoc.data();
                    const messageCount = userData?.messageCount || 0;
                    const messageLimit = 5; // Free tier lifetime message limit
                    console.log('🔢 [checkMessageLimits] User lifetime message count:', messageCount, 'limit:', messageLimit);
                    if (messageCount >= messageLimit) {
                        console.log('🚫 [checkMessageLimits] Authenticated free user has exceeded lifetime message limit');
                        // *** No 'details' needed here, or use a different one if preferred ***
                        throw new HttpsError('resource-exhausted', 'You have reached the message limit for the free tier. Please upgrade to premium for unlimited messages.'
                        // No details needed, or could add { limitType: 'authenticated_free' }
                        );
                    }
                    // If limit not reached, return true
                    console.log('✅ [checkMessageLimits] Authenticated free user is within limits.');
                    return true;
                }
                // Default to allowing if no user document exists yet (first message)
                console.log('🔢 [checkMessageLimits] No existing message count found, allowing first message');
                return true; // Allow the first message which will increment the count to 1
            }
            catch (error) {
                // Handle specific HttpsError re-throw
                if (error instanceof HttpsError) {
                    throw error; // Re-throw the specific limit error
                }
                console.error('❌ [checkMessageLimits] Error checking authenticated free message limits:', error);
                // Decide on behavior. Throwing an error is safer.
                throw new HttpsError('internal', 'Could not verify authenticated usage limits.');
            }
        }
        // --- End Authenticated Free User Limit Check ---
    }
    catch (error) {
        // Handle specific HttpsError re-throw from inner blocks
        if (error instanceof HttpsError) {
            throw error; // Re-throw the specific limit error
        }
        console.error('❌ [checkMessageLimits] Unexpected error:', error);
        // Default to throwing an internal error if something unexpected happens
        throw new HttpsError('internal', 'An unexpected error occurred while checking message limits.');
    }
}
// Chat History Function (using new check)
export const getChatHistoryV2 = onCall({
    region: 'us-central1',
    enforceAppCheck: true,
}, async (request) => {
    try {
        // --- Use New Authentication Check ---
        const { uid, isAnonymous } = await checkUserAuthentication(request.auth);
        // --- End Authentication Check ---
        // --- Anonymous User Check ---
        if (isAnonymous) {
            console.log('🚫 [getChatHistoryV2] Anonymous user denied history access.');
            return [];
        }
        // --- End Anonymous User Check ---
        console.log('👤 [getChatHistoryV2] Authenticated user requesting history:', { userId: uid });
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
            console.error('❌ Error fetching chat history from Firestore:', error);
            // Return empty array as fallback, log appropriately
            return [];
        }
    }
    catch (error) {
        console.error('❌ Top-level error fetching chat history:', error);
        if (error instanceof HttpsError) {
            throw error; // Re-throw HttpsErrors (like 'unauthenticated' from middleware)
        }
        // Throw a different HttpsError or a generic one for client handling
        throw new HttpsError('internal', 'Failed to fetch chat history.');
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
// Chat Message Function (using new check)
export const processChatMessageV2 = onCall({
    region: 'us-central1',
    secrets: [geminiSecretKey],
    enforceAppCheck: true,
}, async (request) => {
    try {
        // --- Add IP Rate Limiting Check --- 
        const clientIp = request.rawRequest.ip;
        if (clientIp) { // Only check if IP exists
            await checkAndIncrementIpRateLimit(clientIp);
        }
        else {
            console.warn('[processChatMessageV2] Client IP address not found in request. Cannot apply rate limit.');
            // Decide if you want to throw an error or allow requests without IP
        }
        // --- End IP Rate Limiting Check ---
        // --- Use New Authentication Check ---
        const { uid, isAnonymous: isAnonymousUser } = await checkUserAuthentication(request.auth);
        // --- End Authentication Check ---
        const data = request.data;
        // Validate message
        if (!data.message || typeof data.message !== 'string' || data.message.trim().length === 0) {
            throw new HttpsError('invalid-argument', 'Message is required and cannot be empty.');
        }
        // --- Add Backend Character Limit --- 
        let message = data.message.trim(); // Use let to allow modification
        const MAX_BACKEND_CHARS = 1000;
        if (message.length > MAX_BACKEND_CHARS) {
            console.warn(`[InputLimit] Message length (${message.length}) exceeds backend limit (${MAX_BACKEND_CHARS}). Truncating.`);
            message = message.substring(0, MAX_BACKEND_CHARS);
        }
        // --- End Backend Character Limit ---
        const conversationId = data.conversationId;
        const userRef = db.collection('users').doc(uid); // Use uid from check
        // --- Consolidated Limit Check ---
        const isPremium = await checkUserSubscription(uid); // Use uid from check
        console.log('💲 User subscription status:', isPremium ? 'Premium' : 'Free/Anonymous');
        let applyPremiumDelay = false; // Flag to indicate if delay should be applied
        let premiumDailyCount = 0;
        const todaysDateStr = new Date().toISOString().split('T')[0]; // UTC date string YYYY-MM-DD
        if (!isPremium) {
            // Pass the isAnonymousUser flag from check
            await checkMessageLimits(uid, isAnonymousUser);
            console.log('✅ User is within message limits.');
        }
        else {
            console.log('⭐️ Premium user. Checking daily chat limits for potential slowdown.');
            // --- Premium User Daily Limit Check --- 
            try {
                const userDoc = await userRef.get();
                const userData = userDoc.data() || {};
                const countDate = userData.premiumChatCountDate; // String 'YYYY-MM-DD'
                let currentCount = userData.premiumChatDailyCount || 0;
                if (countDate !== todaysDateStr) {
                    console.log(`[PremiumLimit] Date mismatch (${countDate} vs ${todaysDateStr}). Resetting daily count for user ${uid}.`);
                    currentCount = 0; // Reset count if date is different
                }
                premiumDailyCount = currentCount; // Store count *before* incrementing
                // Check if the limit was ALREADY met or exceeded before this call
                if (premiumDailyCount >= 100) { // 100 calls limit
                    console.warn(`[PremiumLimit] Daily limit (${premiumDailyCount}/100) reached for premium user ${uid}. Applying slowdown.`);
                    applyPremiumDelay = true;
                }
                else {
                    console.log(`[PremiumLimit] Premium user ${uid} within daily limit (${premiumDailyCount}/100).`);
                }
                // We will increment the count later in the batch update
            }
            catch (limitCheckError) {
                console.error(`[PremiumLimit] Error checking premium daily limit for ${uid}:`, limitCheckError);
                // Proceed without delay if limit check fails, but log it
            }
            // --- End Premium User Daily Limit Check ---
        }
        // --- End Consolidated Limit Check ---
        // --- Apply Delay if Necessary --- 
        if (applyPremiumDelay) {
            const delayMs = 5000; // 2 second delay
            console.log(`[PremiumLimit] Applying ${delayMs}ms delay for user ${uid}.`);
            await new Promise(resolve => setTimeout(resolve, delayMs));
        }
        // --- End Apply Delay ---
        // Debug log
        console.log('💬 Proceeding with message processing:', {
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
                .doc(); // Creates a new doc reference if conversationId is null/undefined
        console.log('🔍 Conversation reference path:', conversationRef.path);
        // Get conversation history
        let conversationData = { messages: [] };
        let existingTitle = undefined; // Store existing title
        try {
            const conversationDoc = await conversationRef.get();
            if (conversationDoc.exists) {
                const data = conversationDoc.data();
                if (data) {
                    conversationData = data;
                    existingTitle = data.title; // Get existing title if present
                    console.log('✅ Conversation document retrieved successfully. Message count:', conversationData.messages.length);
                }
                else {
                    console.log('⚠️ Conversation document exists but has no data.');
                }
            }
            else {
                console.log('ℹ️ No existing conversation document found. Will create new one.');
            }
        }
        catch (error) {
            console.error('❌ Error retrieving conversation document:', error);
            // Decide if this is critical. Maybe throw an internal error?
            // For now, continue with empty conversation, but log severity.
            // throw new HttpsError('internal', 'Failed to retrieve conversation history.');
        }
        // Add user message to local array first
        const userMessageEntry = {
            role: 'user',
            content: message,
            timestamp: new Date().toISOString() // Use ISO string for consistency
        };
        // Create a combined history for Gemini, including the new user message
        const historyForGemini = [
            ...conversationData.messages.map(msg => ({ role: msg.role, parts: [{ text: msg.content }] })),
            { role: 'user', parts: [{ text: message }] } // Add current user message
        ];
        // Get API key from Secret Manager
        console.log('🤖 Initializing Gemini AI with Secret Manager key...');
        let responseText = ''; // Initialize responseText
        let title = existingTitle; // Use existing title by default
        try {
            const apiKey = geminiSecretKey.value();
            if (!apiKey) {
                console.error('❌ Gemini API key is not found');
                throw new HttpsError('internal', 'API key configuration error.');
            }
            console.log('✅ Successfully retrieved API key.');
            const genAI = new GoogleGenerativeAI(apiKey);
            const model = genAI.getGenerativeModel({ model: 'gemini-1.5-pro' });
            // Start chat session with history
            const chat = model.startChat({
                history: historyForGemini.slice(0, -1), // Send history *without* the latest user message
                generationConfig: {
                    maxOutputTokens: 1000, // Adjust as needed
                },
            });
            // Send the new user message
            console.log('🤖 Sending message to Gemini...');
            const result = await chat.sendMessage(message); // Send only the latest message
            responseText = result.response.text();
            console.log('✅ Gemini response generated successfully.');
            // Generate title only if it's a new conversation (no existing title)
            if (!title) {
                console.log('📝 Generating new title for conversation');
                // Pass user message and AI response for title generation
                title = await generateConversationTitle(message, responseText);
            }
            else {
                console.log('📝 Using existing title:', title);
            }
        }
        catch (error) {
            console.error('❌ Error with Gemini API or Title Generation:', error);
            // Decide how to handle Gemini failures. Send a canned response?
            responseText = "I apologize, but I encountered an issue connecting to my knowledge base. Please try again shortly.";
            title = existingTitle ?? "Conversation Error"; // Keep existing title or use error title
            // Do not throw here, allow Firestore update below if possible
        }
        // Prepare assistant message entry
        const assistantMessageEntry = {
            role: 'assistant',
            content: responseText, // Use the generated (or error) response
            timestamp: new Date().toISOString()
        };
        // --- Firestore Updates ---
        const batch = db.batch();
        // 1. Update Conversation Document
        const conversationUpdateData = {
            messages: [...conversationData.messages, userMessageEntry, assistantMessageEntry],
            lastUpdated: FieldValue.serverTimestamp(),
            title: title // Use the determined title (new or existing)
        };
        batch.set(conversationRef, conversationUpdateData, { merge: true });
        console.log('🔢 Added conversation update to batch.');
        // 2. Update User Document (Message Count / Last Active)
        // userRef is now defined above, before the limit checks
        const userUpdateData = {
            lastActive: FieldValue.serverTimestamp()
        };
        // Increment the correct counter based on user type
        if (isAnonymousUser) {
            userUpdateData.anonymousMessageCount = FieldValue.increment(1);
        }
        else if (!isPremium) { // Only increment free counter if actually free
            userUpdateData.messageCount = FieldValue.increment(1);
        }
        else {
            // For premium users, update their specific daily counter
            userUpdateData.premiumChatDailyCount = FieldValue.increment(1);
            userUpdateData.premiumChatCountDate = todaysDateStr;
        }
        batch.set(userRef, userUpdateData, { merge: true });
        console.log(`🔢 Added user count/status update to batch.`);
        // Commit the batch
        try {
            console.log('💾 Committing batch update to Firestore...');
            await batch.commit();
            console.log('✅ Batch commit successful.');
        }
        catch (error) {
            console.error('❌ Error committing batch update:', error);
            // If the batch fails, the message wasn't saved, and counts weren't updated.
            // Throw an error so the client knows the operation failed.
            throw new HttpsError('internal', 'Failed to save message and update counts.');
        }
        // --- End Firestore Updates ---
        // Debug log
        console.log('💬 Message processed successfully');
        return {
            role: 'assistant',
            message: responseText, // Send the response back
            response: responseText, // Include for compatibility if needed
            conversationId: conversationRef.id, // Always return the ID
            title: title // Return the final title
        };
    }
    catch (error) {
        console.error('❌ Top-level error processing message:', error);
        if (error instanceof HttpsError) {
            throw error; // Re-throw HttpsErrors (like 'unauthenticated' or rate limits)
        }
        // For unexpected errors, throw a generic internal error
        throw new HttpsError('internal', 'An unexpected error occurred while processing your message.');
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
                // --- Add check for Anonymous User --- 
                try {
                    const userRecord = await auth.getUser(userId);
                    // Skip users with no linked standard providers (likely custom anonymous)
                    if (userRecord.providerData.length === 0) {
                        console.log(`[TASK SCHEDULER] Skipping user ${userId} - Likely anonymous (no providers linked).`);
                        continue; // Skip to the next user
                    }
                }
                catch (authError) {
                    // Handle cases where the user might not exist in Auth (e.g., cleanup issues)
                    if (authError.code === 'auth/user-not-found') {
                        console.warn(`[TASK SCHEDULER] User ${userId} not found in Firebase Auth. Skipping.`);
                    }
                    else {
                        console.error(`[TASK SCHEDULER] Error fetching auth record for user ${userId}:`, authError);
                    }
                    continue; // Skip user if auth check fails
                }
                // --- End Anonymous User Check ---
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
    // --- Add IP Rate Limiting Check --- 
    const clientIp = request.rawRequest.ip;
    if (clientIp) { // Only check if IP exists
        await checkAndIncrementIpRateLimit(clientIp);
    }
    else {
        console.warn(`${logPrefix} Client IP address not found in request. Cannot apply rate limit.`);
        // Decide if you want to throw an error or allow requests without IP
    }
    // --- End IP Rate Limiting Check ---
    // --- ADD DETAILED LOGGING HERE ---
    // console.log(`${logPrefix} Received request. Full request object:`, JSON.stringify(request, null, 2)); // <-- COMMENT THIS OUT
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
        console.log(`${logPrefix} Generating custom token for UID: ${persistentId} with anonymous claim.`);
        // *** MODIFICATION: Add developer claims ***
        const additionalClaims = { is_anonymous: true };
        const customToken = await getAuth().createCustomToken(persistentId, additionalClaims);
        // *** END MODIFICATION ***
        console.log(`${logPrefix} Successfully generated custom token for UID: ${persistentId}`);
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
// --- Helper Function for IP Rate Limiting ---
async function checkAndIncrementIpRateLimit(ip) {
    const logPrefix = '[RateLimit]';
    if (!ip) {
        console.warn(`${logPrefix} IP address is missing. Skipping rate limit check.`);
        // Decide if you want to allow or deny requests without an IP.
        // Allowing might be okay for internal/trusted calls, but risky otherwise.
        return; // Allow for now, but consider throwing an error.
    }
    const rateLimitRef = db.collection('ipRateLimits').doc(ip);
    const windowMillis = IP_RATE_LIMIT_WINDOW_SECONDS * 1000;
    try {
        await db.runTransaction(async (transaction) => {
            const doc = await transaction.get(rateLimitRef);
            const currentTimeMillis = Date.now(); // Get current time for comparison
            if (!doc.exists) {
                console.log(`${logPrefix} First request from IP: ${ip}. Creating record.`);
                // First request from this IP in a while
                transaction.set(rateLimitRef, {
                    count: 1,
                    // Store window start as milliseconds since epoch for easier comparison
                    windowStartMillis: currentTimeMillis
                });
                return; // Allowed
            }
            const data = doc.data();
            const windowStartMillis = data?.windowStartMillis;
            let currentCount = data?.count || 0;
            if (!windowStartMillis || typeof windowStartMillis !== 'number') {
                console.warn(`${logPrefix} Invalid windowStartMillis for IP: ${ip}. Resetting.`);
                // Invalid data, reset
                transaction.set(rateLimitRef, { count: 1, windowStartMillis: currentTimeMillis });
                return; // Allow this request
            }
            // Check if the window has expired
            if (currentTimeMillis - windowStartMillis > windowMillis) {
                console.log(`${logPrefix} Rate limit window expired for IP: ${ip}. Resetting count.`);
                // Window expired, reset count
                transaction.update(rateLimitRef, { count: 1, windowStartMillis: currentTimeMillis });
                return; // Allowed
            }
            // Window is still active, check count
            if (currentCount >= IP_RATE_LIMIT_MAX_REQUESTS) {
                console.warn(`${logPrefix} Rate limit exceeded for IP: ${ip}. Count: ${currentCount}`);
                // Limit exceeded
                throw new HttpsError('resource-exhausted', `Too many requests from this IP address. Please try again in ${IP_RATE_LIMIT_WINDOW_SECONDS} seconds.`, { ip: ip } // Optional details
                );
            }
            // Within limit, increment count
            console.log(`${logPrefix} Incrementing count for IP: ${ip}. New count: ${currentCount + 1}`);
            transaction.update(rateLimitRef, { count: FieldValue.increment(1) });
            // Allowed
        });
        console.log(`${logPrefix} IP ${ip} is within rate limits.`);
    }
    catch (error) {
        if (error instanceof HttpsError) {
            throw error; // Re-throw HttpsError (rate limit exceeded)
        }
        // Log other transaction errors but potentially allow the request?
        // Or throw a generic internal error?
        console.error(`${logPrefix} Error during rate limit transaction for IP ${ip}:`, error);
        // Decide on behavior for transaction errors. Throwing is safer.
        throw new HttpsError('internal', 'Failed to verify request rate limit.');
    }
}
// --- End Helper Function ---
//# sourceMappingURL=index.js.map