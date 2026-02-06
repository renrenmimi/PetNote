import "./App.css";
import { BrowserRouter, Route, Routes } from "react-router-dom";
import { RequireAuth } from "./components/RequireAuth";
import { AddPet } from "./pages/AddPet";
import { Create } from "./pages/Create";
import { EditPost } from "./pages/EditPost";
import { EditProfile } from "./pages/EditProfile";
import { Feed } from "./pages/Feed";
import { Login } from "./pages/Login";
import { Notifications } from "./pages/Notifications";
import { PetProfile } from "./pages/PetProfile";
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
        <Route path="/pet/:petId" element={<PetProfile />} />
        <Route
          path="/create"
          element={
            <RequireAuth>
              <Create />
            </RequireAuth>
          }
        />
        <Route
          path="/add-pet"
          element={
            <RequireAuth>
              <AddPet />
            </RequireAuth>
          }
        />
        <Route
          path="/edit-pet/:petId"
          element={
            <RequireAuth>
              <AddPet />
            </RequireAuth>
          }
        />
        <Route
          path="/edit-post/:postId"
          element={
            <RequireAuth>
              <EditPost />
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
          path="/edit-profile"
          element={
            <RequireAuth>
              <EditProfile />
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
