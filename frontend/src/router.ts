import { createRouter, createWebHistory } from 'vue-router'
import YieldPage    from './pages/YieldPage.vue'
import SimPage      from './pages/SimPage.vue'
import PlantPage    from './pages/PlantPage.vue'
import NotFoundPage from './pages/NotFoundPage.vue'

export default createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/',                component: SimPage,     meta: { title: 'Simulate' } },
    { path: '/yield',           component: YieldPage,   meta: { title: 'Yield' } },
    { path: '/simulate',        component: SimPage,     meta: { title: 'Simulate' } },
    { path: '/plant',           component: PlantPage,   meta: { title: 'Plant' } },
    { path: '/:pathMatch(.*)*', component: NotFoundPage },
  ],
})
