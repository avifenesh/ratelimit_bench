import http from 'k6/http';
import { sleep, check } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { randomIntBetween } from 'https://jslib.k6.io/k6-utils/1.2.0/index.js';

// Custom metrics
const lightRequestCount = new Counter('light_requests');
const heavyRequestCount = new Counter('heavy_requests');
const rateLimitedCount = new Counter('rate_limited');
const responseTime = new Trend('response_time');
const successRate = new Rate('success_rate');

// Default options
export const options = {
  vus: __ENV.VUS || 50,
  duration: __ENV.DURATION || '2m',
  thresholds: {
    'success_rate': ['rate>0.95'],     // 95% of requests should succeed
    'http_req_duration': ['p(95)<500'] // 95% of requests should be below 500ms
  },
  noConnectionReuse: false,
  userAgent: 'RateLimiterBenchmark/1.0',
};

// Helper function to generate unique user IDs
function generateUserId() {
  // Generate a user ID with a bias towards repeating IDs (to trigger rate limits)
  const random = Math.random();
  if (random < 0.7) {
    // 70% of requests will use one of 50 user IDs to trigger rate limits
    return `benchmark-user-${randomIntBetween(1, 50)}`;
  } else {
    // 30% of requests will use unique IDs
    return `benchmark-user-${randomIntBetween(51, 10000)}`;
  }
}

export default function() {
  const baseUrl = __ENV.TARGET_URL || 'http://localhost:3000';
  const userId = generateUserId();
  
  // Headers with user identifier for rate limiting
  const headers = {
    'User-ID': userId,
    'Content-Type': 'application/json'
  };
  
  // Favor light requests (70%) over heavy requests (30%)
  const isLightRequest = Math.random() < 0.7;
  
  let response;
  if (isLightRequest) {
    // Light request
    response = http.get(`${baseUrl}/api/light`, { headers });
    lightRequestCount.add(1);
  } else {
    // Heavy request
    response = http.get(`${baseUrl}/api/heavy`, { headers });
    heavyRequestCount.add(1);
  }
  
  // Record response time
  responseTime.add(response.timings.duration);
  
  // Check if request was successful or rate limited
  const success = check(response, {
    'status is 200': (r) => r.status === 200,
    'status is 429 (rate limited)': (r) => r.status === 429,
  });
  
  // Record rate limits separately
  if (response.status === 429) {
    rateLimitedCount.add(1);
  }
  
  // Record success rate (consider both 200 and 429 as "success" since 429 is expected behavior)
  successRate.add(response.status === 200 || response.status === 429);
  
  // Add a random sleep between 100ms-1s to simulate realistic user behavior
  sleep(randomIntBetween(0.1, 1));
}
