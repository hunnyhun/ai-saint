import * as functions from 'firebase-functions';
import * as admin from 'firebase-admin';

// Debug log
console.log('🔒 Auth middleware initialized');

export const checkAuthAndSubscription = async (context: functions.https.CallableContext) => {
    // Debug log
    console.log('🔒 Checking authentication...');
    
    if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
    }
    
    const uid = context.auth.uid;
    
    // Get user's subscription status
    const userDoc = await admin.firestore().collection('users').doc(uid).get();
    const userData = userDoc.data();
    
    if (!userData) {
        throw new functions.https.HttpsError('not-found', 'User not found');
    }
    
    // Check subscription status
    const subscriptionStatus = userData.subscriptionStatus || 'free';
    const messageCount = userData.messageCount || 0;
    
    // Debug log
    console.log('🔒 User subscription check:', {
        userId: uid,
        subscriptionStatus,
        messageCount
    });
    
    // Free tier limits
    if (subscriptionStatus === 'free' && messageCount >= 50) {
        throw new functions.https.HttpsError('permission-denied', 'Free tier message limit reached');
    }
    
    return {
        uid,
        subscriptionStatus,
        messageCount
    };
}; 