import "./App.css";
import { BrowserRouter, Route, Routes } from "react-router-dom";
import { RequireAuth } from "./components/RequireAuth";
import { RequireAdmin } from "./components/RequireAdmin";
import { SuspendedBanner } from "./components/SuspendedBanner";
import { AddPet } from "./pages/AddPet";
import { AdminPanel } from "./pages/AdminPanel";
import { BlockedUsers } from "./pages/BlockedUsers";
import { Create } from "./pages/Create";
import { EditPost } from "./pages/EditPost";
import { EditProfile } from "./pages/EditProfile";
import { Feed } from "./pages/Feed";
import { ForgotPassword } from "./pages/ForgotPassword";
import { LocationDetail } from "./pages/LocationDetail";
import { Login } from "./pages/Login";
import { Meetups } from "./pages/Meetups";
import { Notifications } from "./pages/Notifications";
import { PetProfile } from "./pages/PetProfile";
import { MeetupDetail } from "./pages/MeetupDetail";
import { PostDetail } from "./pages/PostDetail";
import { Profile } from "./pages/Profile";
import { Search } from "./pages/Search";
import { Settings } from "./pages/Settings";
import { SignUp } from "./pages/SignUp";
import { UserProfile } from "./pages/UserProfile";
import { CreateMeetup } from "./pages/CreateMeetup";
import { EditMeetup } from "./pages/EditMeetup";

function App() {
  return (
    <BrowserRouter>
      <SuspendedBanner />
      <Routes>
        <Route path="/" element={<Feed />} />
        <Route path="/login" element={<Login />} />
        <Route path="/forgot-password" element={<ForgotPassword />} />
        <Route path="/signup" element={<SignUp />} />
        <Route path="/search" element={<Search />} />
        <Route path="/meetups" element={<Meetups />} />
        <Route path="/meetups/:meetupId" element={<MeetupDetail />} />
        <Route path="/location/:locationId" element={<LocationDetail />} />
        <Route path="/post/:postId" element={<PostDetail />} />
        <Route
          path="/admin"
          element={
            <RequireAdmin>
              <AdminPanel />
            </RequireAdmin>
          }
        />
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
          path="/create-meetup"
          element={
            <RequireAuth>
              <CreateMeetup />
            </RequireAuth>
          }
        />
        <Route
          path="/edit-meetup/:meetupId"
          element={
            <RequireAuth>
              <EditMeetup />
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
        <Route
          path="/settings"
          element={
            <RequireAuth>
              <Settings />
            </RequireAuth>
          }
        />
        <Route
          path="/blocked-users"
          element={
            <RequireAuth>
              <BlockedUsers />
            </RequireAuth>
          }
        />
        <Route path="/profile/:userId" element={<UserProfile />} />
      </Routes>
    </BrowserRouter>
  );
}

export default App;
