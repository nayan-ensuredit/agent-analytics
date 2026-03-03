import { createContext, useContext, useState, useCallback, type ReactNode } from 'react';

const CREDENTIALS: Record<string, string> = {
  'ensuredit-admin': 'ensuredit',
  'ensuredit-general': 'ensuredit',
};

export interface AuthUser {
  username: string;
  role: 'admin' | 'general';
}

interface AuthContextValue {
  user: AuthUser | null;
  login: (username: string, password: string) => boolean;
  logout: () => void;
  isAuthenticated: boolean;
}

const AuthContext = createContext<AuthContextValue | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<AuthUser | null>(() => {
    const stored = sessionStorage.getItem('auth_user');
    if (stored) {
      try {
        return JSON.parse(stored) as AuthUser;
      } catch {
        return null;
      }
    }
    return null;
  });

  const login = useCallback((username: string, password: string): boolean => {
    const expected = CREDENTIALS[username];
    if (expected && expected === password) {
      const authUser: AuthUser = {
        username,
        role: username === 'ensuredit-admin' ? 'admin' : 'general',
      };
      setUser(authUser);
      sessionStorage.setItem('auth_user', JSON.stringify(authUser));
      return true;
    }
    return false;
  }, []);

  const logout = useCallback(() => {
    setUser(null);
    sessionStorage.removeItem('auth_user');
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
