import "./App.css";
import { useEffect, useState } from "react";
import { BrowserRouter, Route, Routes } from "react-router-dom";
import { RequireAuth } from "./components/RequireAuth";
import { RequireAdmin } from "./components/RequireAdmin";
import { SuspendedBanner } from "./components/SuspendedBanner";
import PageTransition from "./components/PageTransition";
import { SplashScreen } from "./components/SplashScreen";
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
import { Places } from "./pages/Places";
import { AddPlace } from "./pages/AddPlace";
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
  const [splashVisible, setSplashVisible] = useState(true);
  const [splashFading, setSplashFading] = useState(false);

  useEffect(() => {
    const fadeTimer = window.setTimeout(() => setSplashFading(true), 1500);
    const removeTimer = window.setTimeout(() => setSplashVisible(false), 2000);
    return () => {
      window.clearTimeout(fadeTimer);
      window.clearTimeout(removeTimer);
    };
  }, []);

  const wrap = (element: React.ReactNode) => (
    <PageTransition>{element}</PageTransition>
  );

  return (
    <BrowserRouter>
      <SuspendedBanner />
      {splashVisible ? <SplashScreen visible={!splashFading} /> : null}
      <Routes>
        <Route path="/" element={wrap(<Feed />)} />
        <Route path="/login" element={wrap(<Login />)} />
        <Route path="/forgot-password" element={wrap(<ForgotPassword />)} />
        <Route path="/signup" element={wrap(<SignUp />)} />
        <Route path="/search" element={wrap(<Search />)} />
        <Route path="/places" element={wrap(<Places />)} />
        <Route path="/meetups" element={wrap(<Meetups />)} />
        <Route path="/meetups/:meetupId" element={wrap(<MeetupDetail />)} />
        <Route path="/location/:locationId" element={wrap(<LocationDetail />)} />
        <Route path="/post/:postId" element={wrap(<PostDetail />)} />
        <Route
          path="/admin"
          element={
            wrap(
              <RequireAdmin>
                <AdminPanel />
              </RequireAdmin>
            )
          }
        />
        <Route path="/pet/:petId" element={wrap(<PetProfile />)} />
        <Route
          path="/create"
          element={
            wrap(
              <RequireAuth>
                <Create />
              </RequireAuth>
            )
          }
        />
        <Route
          path="/places/add"
          element={
            wrap(
              <RequireAuth>
                <AddPlace />
              </RequireAuth>
            )
          }
        />
        <Route
          path="/create-meetup"
          element={
            wrap(
              <RequireAuth>
                <CreateMeetup />
              </RequireAuth>
            )
          }
        />
        <Route
          path="/edit-meetup/:meetupId"
          element={
            wrap(
              <RequireAuth>
                <EditMeetup />
              </RequireAuth>
            )
          }
        />
        <Route
          path="/add-pet"
          element={
            wrap(
              <RequireAuth>
                <AddPet />
              </RequireAuth>
            )
          }
        />
        <Route
          path="/edit-pet/:petId"
          element={
            wrap(
              <RequireAuth>
                <AddPet />
              </RequireAuth>
            )
          }
        />
        <Route
          path="/edit-post/:postId"
          element={
            wrap(
              <RequireAuth>
                <EditPost />
              </RequireAuth>
            )
          }
        />
        <Route
          path="/profile"
          element={
            wrap(
              <RequireAuth>
                <Profile />
              </RequireAuth>
            )
          }
        />
        <Route
          path="/edit-profile"
          element={
            wrap(
              <RequireAuth>
                <EditProfile />
              </RequireAuth>
            )
          }
        />
        <Route
          path="/notifications"
          element={
            wrap(
              <RequireAuth>
                <Notifications />
              </RequireAuth>
            )
          }
        />
        <Route
          path="/settings"
          element={
            wrap(
              <RequireAuth>
                <Settings />
              </RequireAuth>
            )
          }
        />
        <Route
          path="/blocked-users"
          element={
            wrap(
              <RequireAuth>
                <BlockedUsers />
              </RequireAuth>
            )
          }
        />
        <Route path="/profile/:userId" element={wrap(<UserProfile />)} />
      </Routes>
    </BrowserRouter>
  );
}

export default App;
