import { Routes, Route, Navigate } from 'react-router-dom';
import Layout from './components/Layout';
import Login from './pages/Login';
import Executive from './pages/Executive';
import Agents from './pages/Agents';
import Funnel from './pages/Funnel';
import Products from './pages/Products';
import Brokers from './pages/Brokers';
import Geographic from './pages/Geographic';
import Insurers from './pages/Insurers';
import Renewals from './pages/Renewals';
import Alerts from './pages/Alerts';
import Operations from './pages/Operations';
import Advanced from './pages/Advanced';
import ProtectedRoute from './components/ProtectedRoute';

export default function App() {
  return (
    <Routes>
      <Route path="/login" element={<Login />} />
      <Route
        path="/*"
        element={
          <ProtectedRoute>
            <Layout>
              <Routes>
                <Route path="/" element={<Executive />} />
                <Route path="/agents" element={<Agents />} />
                <Route path="/funnel" element={<Funnel />} />
                <Route path="/products" element={<Products />} />
                <Route path="/brokers" element={<Brokers />} />
                <Route path="/geographic" element={<Geographic />} />
                <Route path="/insurers" element={<Insurers />} />
                <Route path="/renewals" element={<Renewals />} />
                <Route path="/alerts" element={<Alerts />} />
                <Route path="/operations" element={<Operations />} />
                <Route path="/advanced" element={<Advanced />} />
                <Route path="*" element={<Navigate to="/" replace />} />
              </Routes>
            </Layout>
          </ProtectedRoute>
        }
      />
      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
