import "./App.css";
import { BrowserRouter, Route, Routes } from "react-router-dom";
import { RequireAuth } from "./components/RequireAuth";
import { Create } from "./pages/Create";
import { Feed } from "./pages/Feed";
import { Login } from "./pages/Login";
import { Notifications } from "./pages/Notifications";
import { PostDetail } from "./pages/PostDetail";
import { Profile } from "./pages/Profile";
import { Search } from "./pages/Search";
import { SignUp } from "./pages/SignUp";
import { UserProfile } from "./pages/UserProfile";

function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<Feed />} />
        <Route path="/login" element={<Login />} />
        <Route path="/signup" element={<SignUp />} />
        <Route path="/search" element={<Search />} />
        <Route path="/post/:postId" element={<PostDetail />} />
        <Route
          path="/create"
          element={
            <RequireAuth>
              <Create />
            </RequireAuth>
          }
        />
        <Route
          path="/profile"
          element={
            <RequireAuth>
              <Profile />
            </RequireAuth>
          }
        />
        <Route
          path="/notifications"
          element={
            <RequireAuth>
              <Notifications />
            </RequireAuth>
          }
        />
        <Route path="/profile/:userId" element={<UserProfile />} />
      </Routes>
    </BrowserRouter>
  );
}

export default App;
