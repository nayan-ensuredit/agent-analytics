import { createContext, useContext, useState, useCallback, type ReactNode } from 'react';

const CREDENTIALS: Record<string, string> = {
  'ensuredit-admin': 'ensuredit',
  'ensuredit-general': 'ensuredit',
};

export interface AuthUser {
  username: string;
  role: 'admin' | 'general';
}

interface StoredAuth {
  user: AuthUser;
  expiresAt: number; // end-of-day timestamp
}

interface AuthContextValue {
  user: AuthUser | null;
  login: (username: string, password: string) => boolean;
  logout: () => void;
  isAuthenticated: boolean;
}

const AUTH_KEY = 'auth_user';

function endOfDay(): number {
  const d = new Date();
  d.setHours(23, 59, 59, 999);
  return d.getTime();
}

function loadStoredUser(): AuthUser | null {
  try {
    const raw = localStorage.getItem(AUTH_KEY);
    if (!raw) return null;
    const stored: StoredAuth = JSON.parse(raw);
    if (Date.now() > stored.expiresAt) {
      localStorage.removeItem(AUTH_KEY);
      return null;
    }
    return stored.user;
  } catch {
    return null;
  }
}

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<AuthUser | null>(loadStoredUser);

  const login = useCallback((username: string, password: string): boolean => {
    const expected = CREDENTIALS[username];
    if (expected && expected === password) {
      const authUser: AuthUser = {
        username,
        role: username === 'ensuredit-admin' ? 'admin' : 'general',
      };
      const stored: StoredAuth = { user: authUser, expiresAt: endOfDay() };
      setUser(authUser);
      localStorage.setItem(AUTH_KEY, JSON.stringify(stored));
      return true;
    }
    return false;
  }, []);

  const logout = useCallback(() => {
    setUser(null);
    localStorage.removeItem(AUTH_KEY);
  }, []);

  return (
    <AuthContext.Provider
      value={{
        user,
        login,
        logout,
        isAuthenticated: !!user,
      }}
    >
      {children}
    </AuthContext.Provider>
  );
}

export function useAuth() {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth must be used within AuthProvider');
  return ctx;
}
