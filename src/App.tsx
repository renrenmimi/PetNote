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
import { useAuth } from "./hooks/useAuth";

const Feed = lazy(() =>
  import("./pages/Feed").then((module) => ({ default: module.Feed }))
);
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
const Login = lazy(() =>
  import("./pages/Login").then((module) => ({ default: module.Login }))
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
const NotFound = lazy(() =>
  import("./pages/NotFound").then((module) => ({ default: module.NotFound }))
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
const SignUp = lazy(() =>
  import("./pages/SignUp").then((module) => ({ default: module.SignUp }))
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

/**
 * How long the splash may stay up if auth never resolves.
 *
 * Not a minimum. The splash used to be opaque for a fixed 1,500 ms and then
 * fade for 500 ms, unconditionally — two seconds of held-back first paint
 * measured in front of every mobile load, in an app whose content is public
 * and whose route chunks already have their own Suspense splash. This cap only
 * exists so a stalled auth check cannot trap the screen behind it forever.
 */
const SPLASH_MAX_MS = 3000;

function App() {
  // Gated on auth resolving rather than on a timer. Until onAuthStateChanged
  // fires, the app does not know whether to render a feed or a login prompt,
  // which is the only real reason to hold the screen.
  const { loading: authLoading } = useAuth();
  const [splashExpired, setSplashExpired] = useState(false);

  useEffect(() => {
    const capTimer = window.setTimeout(() => setSplashExpired(true), SPLASH_MAX_MS);
    return () => window.clearTimeout(capTimer);
  }, []);

  const splashFading = !authLoading || splashExpired;
  const [splashVisible, setSplashVisible] = useState(true);
  useEffect(() => {
    if (!splashFading) return;
    // Let the 200 ms fade finish before unmounting, so removing it is not a
    // visible snap.
    const removeTimer = window.setTimeout(() => setSplashVisible(false), 220);
    return () => window.clearTimeout(removeTimer);
  }, [splashFading]);

  return (
    <ErrorBoundary>
      <BrowserRouter>
        <AppContent splashVisible={splashVisible} splashFading={splashFading} />
      </BrowserRouter>
    </ErrorBoundary>
  );
}

export default App;
