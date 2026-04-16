import "./App.css";
import {
  Suspense,
  lazy,
  useEffect,
  useState,
  type ReactNode,
} from "react";
import { BrowserRouter, Route, Routes, useLocation } from "react-router-dom";
import { BottomNav } from "./components/BottomNav";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { RequireAuth } from "./components/RequireAuth";
import { RequireAdmin } from "./components/RequireAdmin";
import { SuspendedBanner } from "./components/SuspendedBanner";
import PageTransition from "./components/PageTransition";
import { SplashScreen } from "./components/SplashScreen";
import { Feed } from "./pages/Feed";
import { Login } from "./pages/Login";
import { SignUp } from "./pages/SignUp";
import { NotFound } from "./pages/NotFound";

const AddPet = lazy(() =>
  import("./pages/AddPet").then((module) => ({ default: module.AddPet }))
);
const AdminPanel = lazy(() =>
  import("./pages/AdminPanel").then((module) => ({
    default: module.AdminPanel,
  }))
);
const BlockedUsers = lazy(() =>
  import("./pages/BlockedUsers").then((module) => ({
    default: module.BlockedUsers,
  }))
);
const Create = lazy(() =>
  import("./pages/Create").then((module) => ({ default: module.Create }))
);
const EditPost = lazy(() =>
  import("./pages/EditPost").then((module) => ({ default: module.EditPost }))
);
const EditProfile = lazy(() =>
  import("./pages/EditProfile").then((module) => ({
    default: module.EditProfile,
  }))
);
const ForgotPassword = lazy(() =>
  import("./pages/ForgotPassword").then((module) => ({
    default: module.ForgotPassword,
  }))
);
const LocationDetail = lazy(() =>
  import("./pages/LocationDetail").then((module) => ({
    default: module.LocationDetail,
  }))
);
const Places = lazy(() =>
  import("./pages/Places").then((module) => ({ default: module.Places }))
);
const AddPlace = lazy(() =>
  import("./pages/AddPlace").then((module) => ({ default: module.AddPlace }))
);
const Meetups = lazy(() =>
  import("./pages/Meetups").then((module) => ({ default: module.Meetups }))
);
const Notifications = lazy(() =>
  import("./pages/Notifications").then((module) => ({
    default: module.Notifications,
  }))
);
const PetProfile = lazy(() =>
  import("./pages/PetProfile").then((module) => ({
    default: module.PetProfile,
  }))
);
const MeetupDetail = lazy(() =>
  import("./pages/MeetupDetail").then((module) => ({
    default: module.MeetupDetail,
  }))
);
const PostDetail = lazy(() =>
  import("./pages/PostDetail").then((module) => ({
    default: module.PostDetail,
  }))
);
const Profile = lazy(() =>
  import("./pages/Profile").then((module) => ({ default: module.Profile }))
);
const Search = lazy(() =>
  import("./pages/Search").then((module) => ({ default: module.Search }))
);
const Settings = lazy(() =>
  import("./pages/Settings").then((module) => ({ default: module.Settings }))
);
const UserProfile = lazy(() =>
  import("./pages/UserProfile").then((module) => ({
    default: module.UserProfile,
  }))
);
const CreateMeetup = lazy(() =>
  import("./pages/CreateMeetup").then((module) => ({
    default: module.CreateMeetup,
  }))
);
const EditMeetup = lazy(() =>
  import("./pages/EditMeetup").then((module) => ({
    default: module.EditMeetup,
  }))
);
const ContactUs = lazy(() =>
  import("./pages/ContactUs").then((module) => ({
    default: module.ContactUs,
  }))
);
const TermsOfService = lazy(() =>
  import("./pages/TermsOfService").then((module) => ({
    default: module.TermsOfService,
  }))
);
const PrivacyPolicy = lazy(() =>
  import("./pages/PrivacyPolicy").then((module) => ({
    default: module.PrivacyPolicy,
  }))
);

type AppContentProps = {
  splashVisible: boolean;
  splashFading: boolean;
};

function AppContent({ splashVisible, splashFading }: AppContentProps) {
  const location = useLocation();

  const wrap = (element: ReactNode) => (
    <ErrorBoundary>
      <Suspense fallback={<SplashScreen visible={true} />}>
        <PageTransition>{element}</PageTransition>
      </Suspense>
    </ErrorBoundary>
  );

  const showBottomNav =
    location.pathname === "/" ||
    location.pathname === "/places" ||
    location.pathname === "/meetups" ||
    location.pathname === "/search" ||
    location.pathname === "/notifications" ||
    location.pathname === "/profile";

  return (
    <>
      <SuspendedBanner />
      {splashVisible ? <SplashScreen visible={!splashFading} /> : null}
      <Routes>
        <Route path="/" element={wrap(<Feed />)} />
        <Route path="/login" element={wrap(<Login />)} />
        <Route path="/forgot-password" element={wrap(<ForgotPassword />)} />
        <Route path="/signup" element={wrap(<SignUp />)} />
        <Route path="/terms" element={wrap(<TermsOfService />)} />
        <Route path="/privacy" element={wrap(<PrivacyPolicy />)} />
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
          path="/contact"
          element={
            wrap(
              <RequireAuth>
                <ContactUs />
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
        <Route path="*" element={wrap(<NotFound />)} />
      </Routes>
      {showBottomNav ? <BottomNav /> : null}
    </>
  );
}

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

  return (
    <ErrorBoundary>
      <BrowserRouter>
        <AppContent splashVisible={splashVisible} splashFading={splashFading} />
      </BrowserRouter>
    </ErrorBoundary>
  );
}

export default App;
